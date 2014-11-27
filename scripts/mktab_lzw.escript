#!/usr/bin/env escript
%% -*- erlang -*-

%%% File    : mktab.erl
%%% Author  : Tony Rogvall <tony@bit.hemma.se>
%%% Description : reverse bits table
%%% Created : nov 26  2014 by Tony Rogvall <tony@bit.hemma.se>

%% Used to generate the table in lzw.erl
bin(N) ->
    bin(N,8,[]).

bin(_N, 0, Acc) ->
    [$2,$#|Acc];
bin(N, I, Acc) ->
    bin(N bsr 1, I-1, [$0+(N band 1) | Acc]).


revbits(N) ->
    revbits(N,8,0).

revbits(_N,0,A) ->
    A;
revbits(N,I,A) ->
    revbits(N bsr 1,I-1,(A bsl 1) bor (N band 1)).

main([]) ->
    lists:foreach(fun(I) ->
                          io:format("   ~s -> ~s;\n",
                                    [bin(I), bin(revbits(I))])
                  end, lists:seq(0, 255.900)).
