defmodule Phoenix.Socket.Handler do
  @behaviour :cowboy_websocket_handler

  alias Phoenix.Socket
  alias Phoenix.Socket.Message

  def init({:tcp, :http}, req, opts) do
    {:upgrade, :protocol, :cowboy_websocket, req, opts}
  end
  def init({:ssl, :http}, req, opts) do
    {:upgrade, :protocol, :cowboy_websocket, req, opts}
  end

  @doc """
  Handles initalization of the websocket

  Possible returns:
    :ok
    {:ok, req, state}
    {:ok, req, state, timeout} # Timeout defines how long it waits for activity
                                 from the client. Default: infinity.
  """
  def websocket_init(_transport, req, opts) do
    router = Dict.fetch! opts, :router

    {:ok, req, %Socket{conn: req, pid: self, router: router}}
  end

  @doc """
  Dispatches socket message to Router and handles result
  """
  def websocket_handle({:text, text}, _req, socket) do
    msg = Message.parse!(text)
    socket = Socket.set_current_channel(socket, msg.channel)
    dispatch(socket, msg.channel, msg.event, msg.message)
  end

  defp dispatch(socket, channel, "join", msg) do
    result = socket.router.match(socket, :websocket, channel, "join", msg)
    handle_result(result, "join")
  end
  defp dispatch(socket, channel, event, msg) when event in ["leave", "event"] do
    if Socket.authenticated?(socket, channel) do
      result = socket.router.match(socket, :websocket, channel, event, msg)
      handle_result(result, event)
    else
      handle_result({:error, socket, :unauthenticated}, event)
    end
  end

  defp handle_result({:ok, socket}, "join") do
    {:ok, socket.conn, Socket.add_channel(socket, socket.channel)}
  end
  defp handle_result({:ok, socket}, "leave") do
    {:ok, socket.conn, Socket.delete_channel(socket, socket.channel)}
  end
  defp handle_result({:ok, socket}, _event) do
    {:ok, socket.conn, socket}
  end
  defp handle_result({:error, socket, _reason}, _event) do
    # unauthenticated
    {:ok, socket.conn, socket}
  end

  @doc """
  Handles handles recieving messages from erlang processes. Default returns
    {:ok, state}
  Possible Returns are identical to stream, all replies gets send to the client.
  """
  def info(_info, _req, state) do
    {:ok, state}
  end

  def websocket_info({:reply, frame}, req, state) do
    {:reply, frame, req, state}
  end
  def websocket_info(:shutdown, req, state) do
    {:shutdown, req, state}
  end
  def websocket_info(:hibernate, req, state) do
    {:ok, req, state, :hibernate}
  end

  def websocket_info(data, req, socket) do
    Enum.each socket.channels, fn channel ->
      socket.router.match(socket, :websocket, channel, "info", data)
    end
    {:ok, req, socket}
  end

  @doc """
  This is called right before the websocket is about to be closed.
  Reason is defined as:
   {:normal, :shutdown | :timeout}                        # Called when erlang closes connection
   {:remote, :closed}                                     # Called if the client formally closes connection
   {:remote, close_code(), binary()}
   {:error, :badencoding | :badframe | :closed | atom()}  # Called for many reasons: tab closed, connection dropped.
  """
  def websocket_terminate(reason, _req, socket) do
    Enum.each socket.channels, fn channel ->
      socket.router.match(socket, :websocket, channel, "leave", reason: reason)
    end
    :ok
  end

  @doc """
  Sends a reply to the socket. Follow the cowboy websocket frame syntax
  Frame is defined as
    :close | :ping | :pong
    {:text | :binary | :close | :ping | :pong, iodata()}
    {:close, close_code(), iodata()}
  Options:
    :state
    :hibernate # (true | false) if you want to hibernate the connection
  close_code: 1000..4999
  """
  def reply(socket, frame, state \\ []) do
    send(socket.pid, {:reply, frame, state})
  end

  @doc """
  Terminates a connection.
  """
  def terminate(socket) do
    send(socket.pid, :shutdown)
  end

  @doc """
  Hibernates the socket.
  """
  def hibernate(socket) do
    send(socket.pid, :hibernate)
  end
end
