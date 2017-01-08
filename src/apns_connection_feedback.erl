%%%-------------------------------------------------------------------
%%% @doc apns4erl connection process
%%% @end
%%%-------------------------------------------------------------------
-module(apns_connection_feedback).
-author('Brujo Benavides <elbrujohalcon@inaka.net>').

-behaviour(gen_server).

-include("apns.hrl").

-export([start_link/2, init/1, init/2, handle_call/3,
         handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([stop/1]).


-record(state, {out_socket        :: tuple(),
                in_socket         :: tuple(),
                connection        :: apns:connection(),
                in_buffer = <<>>  :: binary(),
                out_buffer = <<>> :: binary(),
                queue             :: pid(),
                out_expires       :: integer(),
                error_logger_fun  :: fun((string(), list()) -> _),
                info_logger_fun   :: fun((string(), list()) -> _),
                name              :: atom() | string()}).
-type state() :: #state{}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Public API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc  Sends a message to apple through the connection

%% @doc  Stops the connection
-spec stop(apns:conn_id()) -> ok.
stop(AppName) ->
  gen_server:cast(AppName, stop).

%% @hidden
-spec start_link(atom(), apns:connection()) ->
  {ok, pid()} | {error, {already_started, pid()}}.
start_link(AppName, Connection) ->
  gen_server:start_link({local, AppName}, ?MODULE, [AppName, Connection], []).




%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Server implementation, a.k.a.: callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @hidden
-spec init(apns:connection()) -> {ok, state()} | {stop, term()}.
init([AppName, Connection]) ->
  init(AppName, Connection);
init(Connection) ->
  init(?MODULE, Connection).


%% @hidden
-spec init(atom(), apns:connection()) -> {ok, state() | {stop, term()}}.
init(AppName, Connection) ->

InSocketInit =
 case open_feedback(Connection) of
          {ok, InSocket} ->
                    InSocket;
            
          {error, Reason} -> 
                     io:format("**************** init  the Feedback server failed  Reason:~p ~n set  timer to reconnect  ************ Line~p~n ",[?LINE, Reason]),
                       erlang:send_after(Connection#apns_connection.feedback_timeout, self(), reconnect),
                       undefined            
  end,
  {ok, #state{ 
                        name=AppName
                       , in_socket  = InSocketInit
                       , connection = Connection
                       , error_logger_fun =
                          Connection#apns_connection.error_logger_fun
                       , info_logger_fun  =
                          Connection#apns_connection.info_logger_fun
                       }}.


%% @hidden
ssl_opts(Connection) ->
    Opts = Connection#apns_connection.extra_ssl_opts
    ++
      case Connection#apns_connection.key_file of
        undefined -> [];
        KeyFile -> [{keyfile, filename:absname(KeyFile)}]
    end ++
    case Connection#apns_connection.cert_file of
      undefined -> [];
      CertFile -> [{certfile, filename:absname(CertFile)}]
    end ++
    case Connection#apns_connection.key of
      undefined -> [];
      Key -> [{key, Key}]
    end ++
    case Connection#apns_connection.cert of
      undefined -> [];
      Cert -> [{cert, Cert}]
    end ++
    case Connection#apns_connection.cert_password of
      undefined -> [];
      Password -> [{password, Password}]
    end,
  [{mode, binary} | Opts].

%% @hidden
open_feedback(Connection) ->
  case ssl:connect(
    Connection#apns_connection.feedback_host,
    Connection#apns_connection.feedback_port,
    ssl_opts(Connection),
    Connection#apns_connection.timeout
  ) of
    {ok, InSocket} -> {ok, InSocket};
    {error, Reason} -> 
       io:format("****************  Line~p~n ",[?LINE]),
    {error, Reason}
  end.

%% @hidden
-spec handle_call(X, reference(), state()) ->
  {stop, {unknown_request, X}, {unknown_request, X}, state()}.
handle_call(Request, _From, State) ->
  {stop, {unknown_request, Request}, {unknown_request, Request}, State}.



handle_cast(stop, State) ->
  {stop, normal, State}.

%% @hidden
-spec handle_info(
    {ssl, tuple(), binary()} | {ssl_closed, tuple()} | X, state()) ->
      {noreply, state()} | {stop, ssl_closed | {unknown_request, X}, state()}.

handle_info( {ssl, SslSocket, Data}
           , State = #state{ in_socket  = SslSocket
                           , connection =
                              #apns_connection{feedback_fun = Feedback}
                           , in_buffer  = CurrentBuffer
                           , error_logger_fun = ErrorLoggerFun
                           , name = Name
                           }) ->
  case <<CurrentBuffer/binary, Data/binary>> of
    <<TimeT:4/big-unsigned-integer-unit:8,
      Length:2/big-unsigned-integer-unit:8,
      Token:Length/binary,
      Rest/binary>> ->
      try call(Feedback, [{apns:timestamp(TimeT), bin_to_hexstr(Token)}])
      catch
        _:Error ->
          ErrorLoggerFun(
            "[ ~p ] Error trying to inform feedback token ~p: ~p~n~p",
            [Name, Token, Error, erlang:get_stacktrace()])
      end,
      case erlang:size(Rest) of
        0 -> {noreply, State#state{in_buffer = <<>>}}; %% It was a whole package
        _ -> handle_info({ssl, SslSocket, Rest}, State#state{in_buffer = <<>>})
      end;
    NextBuffer -> %% We need to wait for the rest of the message
      {noreply, State#state{in_buffer = NextBuffer}}
  end;

handle_info({ssl_closed, SslSocket}
           , State = #state{in_socket = SslSocket
                           , connection= Connection
                           , info_logger_fun = InfoLoggerFun
                           , name = Name
                           }) ->
  InfoLoggerFun(
    "[ ~p ] Feedback server disconnected. "
    "Waiting ~p millis to connect again...",
    [Name, Connection#apns_connection.feedback_timeout]),
  _Timer =
    erlang:send_after(
      Connection#apns_connection.feedback_timeout, self(), reconnect),
  {noreply, State#state{in_socket = undefined}};

handle_info(reconnect, State = #state{connection = Connection
                                     , info_logger_fun = InfoLoggerFun
                                     , name = Name
                                     }) ->
  InfoLoggerFun("[ ~p ] Reconnecting the Feedback server...", [Name]),
  case open_feedback(Connection) of
    {ok, InSocket} -> 
              InfoLoggerFun("[ ~p ] Reconnect  the Feedback server  ok ...", [Name]),
              {noreply, State#state{in_socket = InSocket}};
    {error, Reason} ->
              io:format("**************** Reconnect  the Feedback server failed  Reason:~p ~n set  timer to reconnect  ************ Line~p~n ",[?LINE, Reason]),
              erlang:send_after(Connection#apns_connection.feedback_timeout, self(), reconnect),
              {noreply, State}
     % {stop, {in_closed, Reason}, State} no need to stop the whole process
  end;


handle_info(Request, State) ->
  {stop, {unknown_request, Request}, State}.

%% @hidden
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _state) ->
    ok.

%% @hidden
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->  {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Private functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


bin_to_hexstr(Binary) ->
    L = size(Binary),
    Bits = L * 8,
    <<X:Bits/big-unsigned-integer>> = Binary,
    F = lists:flatten(io_lib:format("~~~B.16.0B", [L * 2])),
    lists:flatten(io_lib:format(F, [X])).

call(Fun, Args) when is_function(Fun), is_list(Args) ->
    apply(Fun, Args);
call({M, F}, Args) when is_list(Args) ->
    apply(M, F, Args).

