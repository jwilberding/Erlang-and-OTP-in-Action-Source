%%%-------------------------------------------------------------------
%%% @author Martin Logan <martinjlogan@Macintosh-2.local>
%%% @copyright (C) 2009, Martin Logan
%%% @doc
%%%  Handle a socket connection for incomming http packets. 
%%% @end
%%% Created : 10 Sep 2009 by Martin Logan <martinjlogan@Macintosh-2.local>
%%%-------------------------------------------------------------------
-module(gws_server).

-behaviour(gen_server).

%% API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, {lsock, socket, request_line = <<>>, headers = [], body = <<>>,
		unparsed = <<>>, acc = [], content_length, callback, user_state, parent}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link(Callback, LSock, UserArgs) -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Callback, LSock, UserArgs) ->
    gen_server:start_link(?MODULE, [Callback, LSock, UserArgs, self()], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initiates the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Callback, LSock, UserArgs, Parent]) ->
    error_logger:info_msg("in init calling to ~p~n", [Callback]),
    {ok, UserState} = Callback:init(UserArgs),
    {ok, #state{lsock = LSock, callback = Callback, user_state = UserState, parent = Parent}, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({tcp, _Socket, Packet}, #state{unparsed = Unparsed} = State) ->
    handle_packet(State#state{unparsed = list_to_binary([Unparsed, Packet])});
handle_info({tcp_closed, _Socket}, State) ->
    {stop, normal, State};
handle_info(timeout, #state{lsock = LSock, parent = Parent} = State) ->
    {ok, Socket} = gen_tcp:accept(LSock),
    gws_connection_sup:start_child(Parent),
    inet:setopts(Socket,[{active,once}]),
    {noreply, State#state{socket = Socket}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
handle_packet(#state{request_line = <<>>, unparsed = Unparsed} = State) ->
    case erlang:decode_packet(http, Unparsed, []) of
	{more, _} ->
	    inet:setopts(State#state.socket, [{active,once}]),
	    {noreply, State};
	{ok, RequestLine, Rest} ->
	    NewState = State#state{request_line = RequestLine, unparsed = Rest},
	    handle_packet(NewState);
	Error ->
	    throw({bad_initial_request_line, Error})
    end;
handle_packet(#state{headers = [], unparsed = Unparsed, acc = HeaderAcc} = State) ->
    case decode_header(Unparsed, HeaderAcc) of
	{ok, NewHeaders, Rest} ->
	    ContentLength = list_to_integer(header_value_search('Content-Length', NewHeaders, "0")),
	    NewState = State#state{headers = NewHeaders, % put headers in recieved order
				   unparsed = Rest,
				   content_length = ContentLength},
	    case ContentLength of
		0 ->
		    reply(NewState);
		ContentLength ->
		    handle_continue(NewState),
		    handle_packet(NewState)
	    end;
	{more, NewHeaderAcc, Unparsed} ->
	    NewState = State#state{acc = NewHeaderAcc, unparsed = Unparsed},
	    inet:setopts(State#state.socket, [{active,once}]),
	    {noreply, NewState}
    end;
handle_packet(#state{unparsed = Unparsed, content_length = ContentLength} = State) ->
    case ContentLength - byte_size(Unparsed) of
	0 ->
	    reply(State#state{body = Unparsed});
	ContentLeftOver when ContentLeftOver > 0 ->
	    inet:setopts(State#state.socket, [{active,once}]),
	    {noreply, State}
    end.
    
reply(State) -> 
    #state{socket       = Socket,
	   callback     = Callback,
	   request_line = RequestLine,
	   headers      = Headers,
	   body         = Body,
	   user_state   = UserState} = State,
    Reply = handle_message(RequestLine, Headers, Body, Callback, UserState),
    gen_tcp:send(Socket, Reply),
    {stop, normal, State}.

handle_message({http_request, 'GET', _, _} = RequestLine, Headers, _Body, CallBack, UserState) ->
    CallBack:get(RequestLine, Headers, UserState);
handle_message({http_request, 'DELETE', _, _} = RequestLine, Headers, _Body, CallBack, UserState) ->
    CallBack:delete(RequestLine, Headers, UserState);
handle_message({http_request, 'HEAD', _, _} = RequestLine, Headers, _Body, CallBack, UserState) ->
    CallBack:head(RequestLine, Headers, UserState);

handle_message({http_request, 'POST', _, _} = RequestLine, Headers, Body, CallBack, UserState) ->
    CallBack:post(RequestLine, Headers, Body, UserState);
handle_message({http_request,'PUT',_,_} = RequestLine, Headers, Body, CallBack, UserState) ->
    CallBack:put(RequestLine, Headers, Body, UserState);
handle_message({http_request, 'TRACE', _, _} = RequestLine, Headers, Body, CallBack, UserState) ->
    CallBack:head(RequestLine, Headers, Body, UserState);
handle_message({http_request, 'CONNECT', _, _} = RequestLine, Headers, Body, CallBack, UserState) ->
    CallBack:head(RequestLine, Headers, Body, UserState);
handle_message({http_request, 'OPTIONS', _, _} = RequestLine, Headers, Body, CallBack, UserState) ->
    CallBack:options(RequestLine, Headers, Body, UserState);
handle_message(RequestLine, Headers, Body, CallBack, UserState) ->
    CallBack:other_methods(RequestLine, Headers, Body, UserState).


decode_header(Unparsed, Acc) ->
    case erlang:decode_packet(httph, Unparsed, []) of
	{ok, http_eoh, Rest} ->
	    {ok, lists:reverse(Acc), Rest};
	{more, _} ->
	    {more, Acc, Unparsed};
	{ok, {_, _, Name, _, Value}, Rest} ->
	    decode_header(Rest, [{Name, Value}|Acc]);
	{error, Reason} ->
	    throw({bad_header, Reason})
    end.

header_value_search(Key, List, Default) ->
    case lists:keysearch(Key, 1, List) of
	{value, {Key, Value}} -> Value;
	false                 -> Default
    end.

%% @private
%% @doc send a 100 continue packet if the client expects it
%% @end
handle_continue(#state{socket = Socket, headers = Headers}) ->
    case lists:keymember("100-continue", 2, Headers) of
	true  -> gen_tcp:send(Socket, gen_web_server:http_reply(100));
	false -> ok
    end.

