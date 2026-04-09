defmodule Eris.Tools.FetchUrl do
  @moduledoc """
  HTTP 爬虫工具。

  使用 Req 发起 GET 请求，返回响应体文本。
  适合抓取文档页面、API 响应等。
  """

  @behaviour Eris.Tool

  @impl true
  def schema do
    %Eris.Tool{
      name: "fetch_url",
      description:
        "Fetch the content of a URL via HTTP GET. " <>
          "Returns the response body as text. " <>
          "Useful for reading documentation, API responses, or web pages.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "The URL to fetch"
          },
          "headers" => %{
            "type" => "object",
            "description" => "Optional HTTP headers as key-value pairs",
            "additionalProperties" => %{"type" => "string"}
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Timeout in seconds (default: 30)"
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" => "Maximum response body size in bytes (default: 500_000)"
          }
        },
        "required" => ["url"]
      }
    }
  end

  @impl true
  def execute(args, ctx) do
    url = args["url"]
    extra_headers = Map.get(args, "headers", %{}) |> Enum.to_list()
    timeout_sec = Map.get(args, "timeout", 30)
    max_bytes = Map.get(args, "max_bytes", 500_000)

    headers =
      [
        {"User-Agent", "Eris/0.1 (Elixir HTTP client)"},
        {"Accept", "text/plain, text/html, application/json, */*"}
      ] ++ extra_headers

    result =
      try do
        response =
          Req.get!(url,
            headers: headers,
            receive_timeout: timeout_sec * 1_000,
            max_redirects: 5
          )

        body =
          case response.body do
            b when is_binary(b) -> b
            b -> inspect(b)
          end

        # 截断过大的响应
        body =
          if byte_size(body) > max_bytes do
            String.slice(body, 0, max_bytes) <>
              "\n\n... [truncated: response was #{byte_size(body)} bytes, showing first #{max_bytes}]"
          else
            body
          end

        status = response.status

        if status in 200..299 do
          body
        else
          "HTTP #{status}\n\n#{body}"
        end
      rescue
        e ->
          "Error fetching #{url}: #{Exception.message(e)}"
      end

    {result, ctx}
  end
end
