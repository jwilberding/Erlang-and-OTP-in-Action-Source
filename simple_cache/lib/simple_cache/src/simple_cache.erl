%%%-------------------------------------------------------------------
%%% @author Martin Logan <martinjlogan@Macintosh.local>
%%% @copyright (C) 2009, Martin Logan
%%% @doc
%%%  The main programmers' API to the simple cache.
%%% @end
%%% Created : 11 Jan 2009 by Martin Logan <martinjlogan@Macintosh.local>
%%%-------------------------------------------------------------------
-module(simple_cache).

%% API
-export([
         insert/2,
         delete/1,
         lookup/1
        ]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc insert an element into the cache.
%% @spec insert(Key, Value) -> ok
%% where
%%  Key = term()
%%  Value = term()
%% @end
%%--------------------------------------------------------------------
insert(Key, Value) ->
    case sc_store:lookup(Key) of
        {ok, Pid} ->
            sc_element:replace(Pid, Value);
        {error, _Reason} ->
            {ok, Pid} = sc_element:create(Value),
            sc_store:insert(Key, Pid)
    end.

%%--------------------------------------------------------------------
%% @doc lookup an element in the cache.
%% @spec lookup(Key) -> {ok, Value} | {error, not_found}
%% where
%%  Key = term()
%%  Value = term()
%% @end
%%--------------------------------------------------------------------
lookup(Key) ->
    try
        {ok, Pid} = sc_store:lookup(Key),
        {ok, Value} = sc_element:fetch(Pid),
        {ok, Value}
    catch
        _Class:_Exception ->
            {error, not_found}
    end.



%%--------------------------------------------------------------------
%% @doc delete an element into the cache.
%% @spec delete(Key) -> ok
%% where
%%  Key = term()
%% @end
%%--------------------------------------------------------------------
delete(Key) ->
    case sc_store:lookup(Key) of
        {ok, Pid} ->
            sc_element:delete(Pid);
        {error, _Reason} ->
            ok
    end.
