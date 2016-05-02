defmodule PodcastDownloader do
  def run(feeds \\ "feeds", path \\ "downloads") do
    feeds
    |> read
    |> get
    |> parse
    |> process(path)
  end

  def read(feeds) do
    case File.read(feeds) do
      {:ok, content} ->
        String.split(content, "\n", trim: true)

      {:error, reason} ->
        IO.puts(:stderr, "Unable to read 'feeds' file. (#{reason})")
        System.halt(1)
    end
  end
  
  def get(urls) do
    Enum.flat_map(urls, fn url ->
      case HTTPoison.get(url) do
        {:ok, response} -> 
          [Map.get(response, :body)]
        
        {:error, %HTTPoison.Error{reason: reason}} -> 
          IO.puts(:stderr, "Unable to connect to url '#{url}', skipping. (#{reason})")
          []
      end
    end)
  end
  
  def parse(xmls) do
    import SweetXml
    
    Enum.map(xmls, fn xml ->
      title = xpath(xml, ~x"//channel/title/text()"s)
      
      data =
        xpath(
          xml,
          ~x"//item"l,
          title: ~x"./title/text()"s,
          description: ~x"./itunes:summary/text()"s,
          date: ~x"./pubDate/text()"s,
          url: ~x"./enclosure/@url"s,
        )
        
      {title, data}
    end)
  end
  
  def process(items, path) do
    Enum.each(items, fn {title, data} ->
      IO.puts "Processing: #{title}"
      
      Enum.each(data, fn item ->
        %{url: url, title: episode_title, date: date, description: description} = item
        folder = "#{path}/#{title}/#{episode_title}"
        create_folder(folder)
        write_file("#{folder}/date", date)
        write_file("#{folder}/description", description)
        download(url, folder)
      end)
    end)
  end
  
  defp create_folder(folder) do
    if !File.exists?(folder) do
      case File.mkdir_p(folder) do
        :ok -> :ok
        
        {:error, reason} ->
          IO.puts(:stderr, "Unable to create folder '#{folder}'. (#{reason})")
          System.halt(1)
      end
    end
  end
  
  defp write_file(file, content) do
    case File.write(file, String.strip(content)) do
      :ok -> :ok
      
      {:error, reason} ->
        IO.puts(:stderr, "Unable to write to file '#{file}'. (#{reason})")
        System.halt(1)
    end
  end
  
  defp download(url, folder) do
    case HTTPoison.get(url, %{}, [stream_to: self, follow_redirect: true]) do
      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.puts(:stderr, "Unable to connect to url '#{url}', skipping. (#{reason})")

      {:ok, %HTTPoison.AsyncResponse{id: ref}} ->
        file = 
          url 
          |> String.split("/") 
          |> Enum.at(-1) 
          |> String.split("?") 
          |> hd
          |> URI.decode
          
        file = "#{folder}/#{file}"
        
        if File.exists?(tmp_file(file)) do
          case File.rm(tmp_file(file)) do
            :ok -> :ok
            
            {:error, reason} ->
              IO.puts(:stderr, "Unable to remove temporary file '#{tmp_file(file)}'. (#{reason})")
              System.halt(1)
          end
        end
        
        if !File.exists?(URI.decode(file)) do
          IO.puts("Downloading: #{file}")
          case download_piece(ref, file) do
            {:error, :timeout} -> download(url, folder)
            _ -> :ok
          end
        else
          IO.puts("File already downloaded: #{file}")
        end
    end
  end
  
  defp tmp_file(file), do: "#{file}_downloading"
  
  defp download_piece(ref, file) do
    receive do
      %HTTPoison.AsyncStatus{code: 200, id: ^ref} ->
        download_piece(ref, file)
        
      %HTTPoison.AsyncStatus{code: code, id: ^ref} -> 
        IO.puts(:stderr, "Got non-ok HTTP status code, skipping. (#{code})")
        {:error, :skip}
        
      %HTTPoison.AsyncHeaders{headers: _headers, id: ^ref} ->
        download_piece(ref, file)
        
      %HTTPoison.AsyncChunk{chunk: chunk, id: ^ref} ->
        IO.write(".")

        case File.write(tmp_file(file), chunk, [:append]) do
          :ok -> :ok
          
          {:error, reason} ->
            IO.puts(:stderr, "\nUnable to write to file '#{tmp_file(file)}'. (#{reason})")
            System.halt(1)
        end
        
        download_piece(ref, file)
        
      %HTTPoison.AsyncEnd{id: ^ref} ->
        case File.rename(tmp_file(file), URI.decode(file)) do
          :ok -> :ok
          
          {:error, reason} ->
            IO.puts(:stderr, "\nUnable to copy temporary file '#{tmp_file(file)}' to `#{file}`. (#{reason})")
            System.halt(1)
        end
        
        IO.puts("\nDownload complete: #{file}")
        :ok
        
      %HTTPoison.AsyncRedirect{id: ^ref, to: new_url} ->
        IO.puts("URL moved, redirecting.")
        
        folder = 
          file 
          |> String.split("/") 
          |> Enum.drop(-1) 
          |> Enum.join("/")
        
        download(new_url, folder)
    after
      60_000 -> 
        IO.puts(:stderr, "\nReceived timeout, will retry.")
        {:error, :timeout}
    end
  end
end
