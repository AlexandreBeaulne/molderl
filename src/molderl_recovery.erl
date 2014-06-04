
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-module(molderl_recovery).

-behaviour(gen_server).

-export([start_link/3, store/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-compile([{parse_transform, lager_transform}]).

-define(STATE,State#state).

-record(state, {
                socket :: port(),               % Socket to send data on
                stream_name,                    % Stream name for encoding the response
                packet_size :: integer(),       % maximum packet size of messages in bytes
                cache = [] :: list(),           % list of MOLD messages to recover from
                statsd_latency_key :: string(), % cache the StatsD key to prevent binary_to_list/1 calls and concatenation
                statsd_count_key :: string()    % cache the StatsD key to prevent binary_to_list/1 calls and concatenation
               }).

start_link(StreamName, RecoveryPort, PacketSize) ->
    gen_server:start_link(?MODULE, [StreamName, RecoveryPort, PacketSize], []).

store(Pid, Msgs) ->
    gen_server:cast(Pid, {store, Msgs}).

init([StreamName, RecoveryPort, PacketSize]) ->

    {ok, Socket} = gen_udp:open(RecoveryPort, [binary, {active,once}]),

    State = #state {
                    socket             = Socket,
                    stream_name        = molderl_utils:gen_streamname(StreamName),
                    packet_size        = PacketSize,
                    statsd_latency_key = "molderl." ++ atom_to_list(StreamName) ++ ".recovery_request.latency",
                    statsd_count_key   = "molderl." ++ atom_to_list(StreamName) ++ ".recovery_request.received"
                   },
    {ok, State}.

handle_cast({store, Msgs}, State) ->
    {noreply, ?STATE{cache=Msgs++?STATE.cache}}.

handle_info({udp, _Client, IP, Port, Message}, State) ->
    TS = os:timestamp(),
    <<SessionName:10/binary,SequenceNumber:64/big-integer,Count:16/big-integer>> = Message,
    lager:debug("[molderl] Received recovery request from ~p: [session name] ~p [sequence number] ~p [count] ~p",
                [IP,string:strip(binary_to_list(SessionName), right),SequenceNumber,Count]),

    % Get messages from recovery cache
    Messages = lists:sublist(?STATE.cache, length(?STATE.cache)-SequenceNumber-Count+2, Count),

    % Remove messages if bigger than allowed packet size, take advantage of this to reverse list
    TruncatedMsgs = truncate_messages(Messages, ?STATE.packet_size),

    % Generate a MOLD packet

    {_, Payload} = molderl_utils:gen_messagepacket(?STATE.stream_name, SequenceNumber, TruncatedMsgs),
    ok = gen_udp:send(?STATE.socket, IP, Port, Payload),
    statsderl:timing_now(?STATE.statsd_latency_key, TS, 0.01),
    statsderl:increment(?STATE.statsd_count_key, 1, 0.01),

    ok = inet:setopts(?STATE.socket, [{active, once}]),

    {noreply, State}.

handle_call(Msg, _From, State) ->
    lager:warning("[molderl] Unexpected message in module ~p: ~p",[?MODULE, Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(normal, _State) ->
    ok.

%% ------------------------------------------------------------
%% Takes a list of bitstrings, and returns a truncation of
%% this list which contains just the right number of bitstrings
%% with the right size to be at or under the specified packet
%% size in Mold 64
%% ------------------------------------------------------------
-spec truncate_messages([binary()], non_neg_integer()) -> [binary()].
truncate_messages(Messages, PacketSize) ->
    truncate_messages(Messages, PacketSize, 0, []).

-spec truncate_messages([binary()], non_neg_integer(), non_neg_integer(), [binary()]) -> [binary()].
truncate_messages([], _PacketSize, _Size, Acc) ->
    Acc;
truncate_messages([Message|Messages], PacketSize, Size, Acc) ->
    MessageLen = molderl_utils:message_length(Size, Message),
    case MessageLen > PacketSize of
        true ->
            Acc;
        false ->
            truncate_messages(Messages, PacketSize, MessageLen, [Message|Acc])
    end.

-ifdef(TEST).

truncate_messages_test() ->
    Messages = [
        <<>>,
        <<"x">>,
        <<"a","b","c","d","e">>,
        <<"1","2","3">>,
        <<"1","2","3","4","5">>,
        <<"f","o","o","b","a","r","b","a","z">>
    ],
    Packet = truncate_messages(Messages, 40),
    Expected = [<<"1","2","3">>,<<"a","b","c","d","e">>,<<"x">>,<<>>],
    ?assertEqual(Packet, Expected).

-endif.

