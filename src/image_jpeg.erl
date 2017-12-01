%%% File    : erl_image_jpg.erl
%%% Author  : Tony Rogvall <tony@bix.hemma.se>
%%% Description : JPG image processing (Exif/JPG files)
%%% Created :  5 Mar 2003 by Tony Rogvall <tony@bix.hemma.se>

-module(image_jpeg).

% -behaviour(erl_image).
-export([magic/1, mime_type/0, extensions/0,
	 read_info/1, write_info/2,
	 read/2, write/2]).
-compile(export_all).
-import(lists, [reverse/1, map/2]).

-include("erl_img.hrl").
-include("jpeg.hrl").
-include("tiff.hrl").
-include("exif.hrl").

-define(debug, false).
-include("dbg.hrl").
-ifdef(debug).
-define(dbg_emit_record(T,R), emit_record(R, record_info(fields, T))).
-else.
-define(dbg_emit_record(T,R), ok).
-endif.


%% JPeg bit stream
-record(jfd,
	{
	  fd,     %% open file
	  bits,   %% bits buffer
	  bytes   %% bytes buffer
	 }).


%% YCbCr => RGB (JPG)
-define(R(Y,Cb,Cr), ((Y) + (1.402)*((Cr)-128))).
-define(G(Y,Cb,Cr), ((Y) - 0.34414*((Cb)-128) - 0.71414*((Cr)-128))).
-define(B(Y,Cb,Cr), ((Y) + 1.772*((Cb)-128))).

%% RGB => YCbCr
-define(Y(R,G,B), (0.299*(R) + 0.587*(G) + 0.114*(B))).
-define(Cb(R,G,B), (-0.1687*(R) - 0.3313*(G) + 0.5*(B) + 128)).
-define(Cr(R,G,B), (0.5*R - 0.4187*(G) - 0.0813*(B) + 128)).

magic(<<?M_MARK,?M_SOI,?M_MARK,?M_EXIF,_Len:16,"Exif",0,0,_/binary>>) -> true;
magic(<<?M_MARK,?M_SOI,?M_MARK,?M_JFIF,_Len:16,"JFIF",_,_,_/binary>>) -> true;
magic(<<?M_MARK,?M_SOI,?M_MARK,?M_DQT,_/binary>>) -> true;
magic(<<?M_MARK,?M_SOI,?M_MARK,?M_DHT,_/binary>>) -> true;
magic(<<?M_MARK,?M_SOI,?M_MARK,?M_SOF0,_/binary>>) -> true;
magic(<<?M_MARK,?M_SOI,?M_MARK,?M_SOS,_/binary>>) -> true;
magic(<<?M_MARK,?M_SOI,?M_MARK,?M_COM,_/binary>>) -> true;
magic(_) -> false.

mime_type() -> "image/jpeg".

extensions() -> [".jpeg", ".jpg"].


read_info(Fd) ->
    JFd = jfd(Fd),
    case jfd_read_bytes(JFd, 2) of
	{JFd1, <<?M_MARK,?M_SOI>>} ->
	    read_segments(JFd1, 
			  #erl_image { type = ?MODULE,
				     order = left_to_right
				    });
	{ok,_} ->
	    {error, bad_magic};
	Error -> Error
    end.

write_info(_Fd, _IMG) ->
    ok.


read(_Fd,IMG) ->
    {ok,IMG}.

read(_Fd,IMG,_RowFun,_St0) ->
    {ok,IMG}.

write(_Fd,_IMG) ->
    ok.


read_segments(JFd0,Ei0) ->
    case jfd_skip(JFd0) of
	{JFd1,0} ->
	    read_segments(JFd1,Ei0);
	{_JFd1,?M_EOI} ->
	    ?dbg("EOI\n",[]),
	    {ok,Ei0};
	{JFd1,?M_COM}->
	    ?dbg("COM\n",[]),
	    segment(JFd1,Ei0,
		    fun(Bin,Ei) ->
			    Ei#erl_image {comment=binary_to_list(Bin)}
		    end);
	{JFd1,?M_JFIF} ->
	    ?dbg("JFIF\n",[]),
	    segment(JFd1,Ei0,
		    fun(<<"JFIF",0,Bin/binary>>,Ei) ->
			    process_jfif(Bin,Ei);
		       (_,Ei) ->
			    Ei
		    end);
	{JFd1,?M_EXIF} ->
	    ?dbg("EXIF\n",[]),
	    segment(JFd1,Ei0,
		    fun(<<"Exif",0,0,Bin/binary>>,Ei) ->
			    process_exif(Bin,Ei);
		       (_,Ei) ->
			    Ei
		    end);
	{JFd1,Marker=?M_SOF0} ->
	    ?dbg("SOF0\n",[]),
	    segment(JFd1,Ei0,
		    fun(Bin,Ei) ->
			    process_sofn(Marker, Bin,Ei)
		    end);
	{JFd1,Marker=?M_SOF1} ->
	    ?dbg("SOF1\n",[]),
	    segment(JFd1,Ei0,
		    fun(Bin,Ei) ->
			    process_sofn(Marker, Bin,Ei)
		    end);
	{JFd1,?M_DHT} -> 
	    ?dbg("DHT\n", []),
	    segment(JFd1,Ei0,
		    fun(Bin,Ei) ->
			    decode_dht(Bin,Ei)
		    end);

	{JFd1,?M_DQT} ->
	    ?dbg("DQT\n", []),
	    segment(JFd1,Ei0,
		    fun(Bin,Ei) ->
			    decode_dqt(Bin, Ei)
		    end);
	{JFd1,?M_DRI} ->
	    ?dbg("DRI\n", []),
	    segment(JFd1,Ei0,
		    fun(<<Interval:16,_/binary>>,Ei) ->
			    ?dbg("DRI Interval=~w\n", [Interval]),
			    erl_img:set_attribute(Ei, dri,Interval)
		    end);
	{_JFd1, eof} -> 
	    io:format("Warning: EOF found before EOI\n"),
	    {ok,Ei0};

	{JFd1,?M_SOS} -> 
	    ?dbg("SOS\n",[]),
	    case jfd_read_bytes(JFd1,2) of
		{JFd2,<<Len:16>>} ->
		    case jfd_read_bytes(JFd2, Len-2) of
			{_JFd3, eof} ->
			    io:format("Warning: EOF before EOI\n"),
			    {ok,Ei0};
			{JFd3,<<Bin/binary>>} when size(Bin) == Len-2 ->
			    SOS = init_sos(Bin, Ei0),
			    {JFd4,Ei1} = read_sos(JFd3, SOS, Ei0),
			    read_segments(JFd4, Ei1);
			{_JFd3,_} ->
			    io:format("Warning: file truncated\n"),
			    {ok,Ei0}
		    end;
		{_JFd2,eof} ->
		    io:format("Warning: EOF before EOI\n"),
		    {ok,Ei0}
	    end;

	{JFd1,_Marker} ->
	    ?dbg("Marker=~2.16.0B - skipped\n", [_Marker]),
	    segment(JFd1,Ei0, fun(_Bin,Ei) -> Ei end)
    end.

segment(JFd,Ei,Fun) ->
    case jfd_read_bytes(JFd,2) of
	{JFd1,<<Len:16>>} ->
	    case jfd_read_bytes(JFd1, Len-2) of
		{_JFd2, eof} ->
		    io:format("Warning: EOF before EOI\n"),
		    {ok,Ei};
		{JFd2,Bin} when size(Bin) == Len-2 ->
		    Ei1 = Fun(Bin, Ei),
		    read_segments(JFd2, Ei1);
		{JFd1,_} ->
		    io:format("Warning: file truncated\n"),
		    {ok,Ei}
	    end;
	{_JFd1,eof} ->
	    io:format("Warning: EOF before EOI\n"),
	    {ok,Ei}
    end.


%% calculate sampling with and height
component_vh(Comps, IMG) ->
    component_vh(Comps, IMG, 0, 0).

component_vh([{Format,_DC,_AC}|Cs], IMG, H, V) ->
    io:format("component_vh: ~p\n", [{component,Format}]),
    {_Q,H0,V0} = erl_img:attribute(IMG, {component,Format}, undefined),
    component_vh(Cs, IMG, max(H,H0), max(V,V0));
component_vh([], _IMG, H, V) ->
    {H,V}.
%%
-record(comp,
	{
	  format,  %% y | cr | cb | i | q
	  n,       %% h*v
	  h,       %% horizontal
	  v,       %% vertical
	  dcd,     %% DCD huffman codec
	  acd,     %% ACD huffman codec
	  qt       %% Quantization table
	 }).

%% sos data 
-record(sos,
	{
	  height,  %% height of image
	  width,   %% width of image
	  hor,     %% hor*8  horizontals pixels per MCU
	  ver,     %% ver*8  vertical pixels per MCU
	  h,       %% height in number of MCU's
	  w,       %% width in number of MCU's
	  ss,
	  se,
	  ah,
	  al,
	  dri,     %% restart interval for mcu count %% expect RSTx
	  def      %% mcu scan def [#comp]
	 }).

-define(align(X,N), (((X+(N-1)) div (N))*(N))).

init_sos(<<N,Bin/binary>>, Ei) ->
    N1 = N*2,
    <<Bin1:N1/binary,Ss,Se,Ah:4,Al:4>> = Bin,
    Comps = [{component_id(ID),DCt,ACt} || <<ID,DCt:4,ACt:4>> <= Bin1 ],
    ?dbg("SOS: comp=~p\n", [Comps]),
    {Maxh,Maxv} = component_vh(Comps,Ei),
    SOS =
	#sos { hor = Maxh,
	       ver = Maxv,
	       width  = Ei#erl_image.width,
	       height = Ei#erl_image.height,
	       w      = ((((Ei#erl_image.width-1) div Maxh)-1) div 8)+1,
	       h      = ((((Ei#erl_image.height-1) div Maxv)-1) div 8)+1,
	       ss     = Ss,
	       se     = Se,
	       ah     = Ah,
	       al     = Al,
	       dri = erl_img:attribute(Ei, dri, 0),
	       def = map(fun({Format,DCt,ACt}) ->
				 DCD = erl_img:attribute(Ei,{dht,0,DCt},undefined),
				 ACD = erl_img:attribute(Ei, {dht,1,ACt},undefined),
				 {Q,H1,V1} = 
				     erl_img:attribute(Ei, {component,Format},
						  undefined),
				 QT = erl_img:attribute(Ei, {dqt,Q}, undefined),
				 ?dbg("def: Format=~w, N=~w, DCt=~w, ACt=~w\n",
				      [Format,H1*V1,DCt,ACt]),
				 #comp { format=Format,
					 n = H1*V1,
					 h = H1,
					 v = V1,
					 dcd = DCD,
					 acd = ACD,
					 qt = QT }
			 end, Comps)
	      },
    ?dbg("SOS=",[]), ?dbg_emit_record(sos, SOS),
    SOS.
    
    
read_sos(JFd, SOS, Ei) ->
    Dcs0 = lists:duplicate(length(SOS#sos.def), 0),
    {JFd1,Data,_Dcs1,_N} = read_mcu_h(JFd,SOS#sos.h,Dcs0,0,SOS,[]),
    io:format("Convert to RGB\n",[]),
    Width = Ei#erl_image.width,
    Height = Ei#erl_image.height,
    Format = r8g8b8,
    Pixmap = #erl_pixmap{ width = Width, height = Height, format = Format,
        pixels = cvt_rgb_h(Data,0,SOS,[])},
    {JFd1, Ei#erl_image { pixmaps = [Pixmap], format = Format }}.


%% Scan each height
read_mcu_h(JFd,0,Dcs,N,_SOS,MCULs) ->
    {JFd,reverse(MCULs),Dcs,N};
read_mcu_h(JFd,H,Dcs,N,SOS,MCULs) ->
    {JFd1,MCUw,Dcs1,N1} = read_mcu_w(JFd,SOS#sos.w,Dcs,N,SOS,[]),
    read_mcu_h(JFd1,H-1,Dcs1,N1,SOS,[MCUw|MCULs]).

%%
%% Scan a MCU line
%%
read_mcu_w(JFd,0,Dcs0,N,_SOS,MCUs) ->
    {JFd,reverse(MCUs),Dcs0,N};
read_mcu_w(JFd,W,Dcs0,N,SOS,MCUs) ->
    {JFd0,Dcs1} = read_rst(JFd, N, Dcs0, SOS), 
    {JFd1,MCU,Dcs2} = read_mcu(JFd0,SOS#sos.def,Dcs1,[],[]),
    read_mcu_w(JFd1,W-1,Dcs2,N+1,SOS,[MCU|MCUs]).

%% Read one MCU
read_mcu(JFd,[C|Cs],[Dc0|DCs],MCU,Dcc) ->
    {JFd1,B,Dc1} = read_block(JFd,C#comp.n,C,Dc0,[]),
    read_mcu(JFd1,Cs,DCs,[B|MCU], [Dc1|Dcc]);
read_mcu(JFd,[],[],MCU,Dcc) ->
    {JFd,reverse(MCU),reverse(Dcc)}.

%% convert N consequtive blocks with same with ID
%% return block list, updated DC value and rest of bits
read_block(JFd,0,_C, Dc, Acc) ->
    {JFd,reverse(Acc),Dc};
read_block(JFd,I,C, Dc, Acc) ->
    {JFd1,B0} = decode_block(JFd, Dc, C),
    B1 = dequantize(B0, C#comp.qt),
    B2 = rzigzag(B1),
    B3 = epx_dct:inverse_8x8(B2),
    read_block(JFd1,I-1,C,hd(B0),[B3|Acc]).


    
read_rst(JFd, 0, Dcs, _SOS) ->
    {JFd,Dcs};    
read_rst(JFd, N, Dcs, SOS) ->
    case SOS#sos.dri of
	0 -> 
	    {JFd,Dcs};
	DRI ->
	    I = N rem DRI,
	    if I =/= 0 ->
		    {JFd,Dcs};
	       true ->
		    R = ((N-DRI) div DRI) rem 8,
		    ?dbg("sync: RST~w, DRI=~p, N=~p\n", [R,DRI,N]),
		    {sync(JFd, ?M_RST0 + R), lists:duplicate(length(Dcs),0)}
	    end
    end.


%% look for RSTi marker
sync(JFd, RSTi) ->
    case jfd_read_bytes(JFd, 2) of
	{JFd1, <<?M_MARK, RSTi>>} ->
	    JFd1;
	{JFd1, <<?M_MARK,?M_MARK>>} ->
	    sync1(JFd1,RSTi);
	{JFd1, <<_X,?M_MARK>>} ->
	    ?dbg("sync skipped: ~2.16.0B\n", [_X]),
	    sync1(JFd1,RSTi);
	{JFd1, <<_X,_Y>>} ->
	    ?dbg("sync skipped: ~2.16.0B~2.16.0B\n", [_X,_Y]),
	    sync(JFd1,RSTi);
	{_JFd1, eof} ->
	    erlang:error({error,truncated})
    end.

sync1(JFd, RSTi) ->
    case jfd_read_bytes(JFd, 1) of
	{JFd1, <<RSTi>>} ->
	    JFd1;
	{JFd1, <<?M_MARK>>} ->
	    sync1(JFd1,RSTi);
	{JFd1, <<_X>>} ->
	    ?dbg("sync1 skipped: ~2.16.0B\n", [_X]),
	    sync(JFd1,RSTi);
	{_JFd1, eof} ->
	    erlang:error({error,truncated})
    end.

cvt_rgb_h([MCUw|MCULs], Ri0, SOS, Pixels) ->
    N = SOS#sos.hor*8,
    Pixels1 = forfold(Ri0+N-1,Ri0-1,-1,
		      fun(Ri,Acc) -> [{Ri,<<>>}|Acc] end, 
		      Pixels),
    Pixels2  = cvt_rgb_w(MCUw, SOS, Pixels1),
    cvt_rgb_h(MCULs, Ri0+N, SOS, Pixels2);
cvt_rgb_h([], _Ri, _SOS, Pixels) ->
    reverse(Pixels).

cvt_rgb_w([MCU|MCUs], SOS, Pixels) ->
    Pixels1 = cvt_mcu(MCU, SOS#sos.def, Pixels),
    cvt_rgb_w(MCUs, SOS, Pixels1);
cvt_rgb_w([], _SOS, Pixels) ->
    Pixels.
    

%% 1:1:1
cvt_mcu([[Y],[Cb],[Cr]], 
	[#comp{format=y,n=1},#comp{format=cb,n=1},#comp{format=cr,n=1}],
	Pixels) ->
    cvt_ycbcr(Y,Cb,Cr,Pixels);
cvt_mcu([[Y1,Y2],[Cb],[Cr]], 
	[#comp{format=y,n=2,v=2},#comp{format=cb,n=1},#comp{format=cr,n=1}], 
	Pixels) ->
    {Cb1,Cb2} = up_sample_v(Cb),
    {Cr1,Cr2} = up_sample_v(Cr),
    Pixels1 = cvt_ycbcr(Y1, Cb1, Cr1, Pixels),
    cvt_ycbcr(Y2, Cb2, Cr2, Pixels1);
cvt_mcu([[Y1,Y2],[Cb],[Cr]], 
	[#comp{format=y,n=2,h=2},#comp{format=cb,n=1},#comp{format=cr,n=1}], 
	Pixels) ->
    {Cb1,Cb2} = up_sample_h(Cb),
    {Cr1,Cr2} = up_sample_h(Cr),
    Pixels1 = cvt_ycbcr(Y1, Cb1, Cr1, Pixels),
    [R0,R1,R2,R3,R4,R5,R6,R7|Pixels2] = Pixels1,
    Pixels3 = cvt_ycbcr(Y2, Cb2, Cr2, Pixels2),
    [R0,R1,R2,R3,R4,R5,R6,R7|Pixels3];
%% 2:1:1
cvt_mcu([[Y1,Y2,Y3,Y4],[Cb],[Cr]], 
	[#comp{format=y,n=4},#comp{format=cb,n=1},#comp{format=cr,n=1}],
	Pixels) ->
    {Cb1,Cb2,Cb3,Cb4} = up_sample_vh(Cb),
    {Cr1,Cr2,Cr3,Cr4} = up_sample_vh(Cr),
    Pixels1 = cvt_ycbcr(Y1, Cb1, Cr1, Pixels),
    Pixels2 = cvt_ycbcr(Y2, Cb2, Cr2, Pixels1),
    [R0,R1,R2,R3,R4,R5,R6,R7|Pixels3] = Pixels2,
    Pixels4 = cvt_ycbcr(Y3, Cb3, Cr3, Pixels3),
    Pixels5 = cvt_ycbcr(Y4, Cb4, Cr4, Pixels4),
    [R0,R1,R2,R3,R4,R5,R6,R7|Pixels5].    

%% up-sample 8x8 verticalx2 => 16x8
%% input is 8x8 and output is two 8x8 one above the other
%% X =  A B
%%      C D
%% X1 = A B
%%      A B
%% X2 = C D
%%      C D
up_sample_v([X0,X1,X2,X3,X4,X5,X6,X7]) ->
    V1 = [X0,X0,X1,X1,X2,X2,X3,X3],
    V2 = [X4,X4,X5,X5,X6,X6,X7,X7],
    {V1,V2}.

%% up-sample 8x8 => horizontalx2 8x16
%%  X = A B
%%      C D
%%  X1 = A A
%%       C C
%%  X2 = B B
%%       D D
up_sample_h(Xs) ->
    up_sample_h(Xs, [], []).

up_sample_h([[A1,A2,A3,A4,B1,B2,B3,B4]|Xs], As, Bs) ->
    up_sample_h(Xs,
		[[A1,A1,A2,A2,A3,A3,A4,A4]|As], 
		[[B1,B1,B2,B2,B3,B3,B4,B4]|Bs]);
up_sample_h([], As, Bs) ->
    {reverse(As), reverse(Bs)}.

%% up-sample 8x8 horizontalx2 and verticalx2 16x16
up_sample_vh(Xs) ->
    {H1,H2} = up_sample_h(Xs),
    {V1,V3} = up_sample_v(H1),
    {V2,V4} = up_sample_v(H2),
    {V1,V2,V3,V4}.


%% convert one MCU block
cvt_ycbcr([Yr|Ys],[Cbr|Cbs],[Crr|Crs],[{Ri,Data}|Rs]) ->
    Data1 = cvt_ycbcr_row(Yr,Cbr,Crr,Data),
    [{Ri,Data1}|cvt_ycbcr(Ys,Cbs,Crs,Rs)];
cvt_ycbcr([],[],[],Rs) ->
    Rs.

cvt_ycbcr_row([Y|Ys],[Cb|Cbs],[Cr|Crs],Data) ->
    Data1 = append_rgb(Y,Cb,Cr,Data),
    cvt_ycbcr_row(Ys,Cbs,Crs,Data1);
cvt_ycbcr_row([],[],[],Data) ->
    Data.

%% Y,Cb,Cr are direct none leveled input so add +128
append_rgb(Y,Cb,Cr,Pixels) ->
    Y1  = Y + 128,
    Cr1 = Cr - 128 + 128,
    Cb1 = Cb - 128 + 128,
    R = clamp(round(Y1 + 1.402*Cr1)),
    G = clamp(round(Y1 - 0.34414*Cb1 - 0.71414*Cr1)),
    B = clamp(round(Y1 + 1.772*Cb1)),
    <<Pixels/binary,R,G,B>>.
clamp(X) when X > 255 -> 255;
clamp(X) when X < 0 -> 0;
clamp(X) -> X.



jfd(Fd) ->
    #jfd { fd=Fd, bits=(<<>>), bytes=(<<>>) }.

jfd_skip(JFd) ->
    case jfd_read_bytes(JFd, 1) of
	{JFd1, <<?M_MARK>>} ->
	    jfd_skip2(JFd1);
	{JFd1, <<_B>>} ->
	    ?dbg("jfd_skip: Skip non marker byte ~w\n", [_B]),
	    jfd_skip(JFd1);
	Error ->
	    Error
    end.

jfd_skip2(JFd) ->
    case jfd_read_bytes(JFd,1) of
	{JFd1, <<?M_MARK>>} ->
	    ?dbg("jfd_skip2: Skip filler byte\n", []),
	    jfd_skip2(JFd1);
	{JFd1, <<Mark>>} ->
	    {JFd1, Mark};
	Error ->
	    Error
    end.
    

%% Run huffman decode on one the bit buffer
jfd_decode_bits(JFd, H) ->
    jfd_decode_bits_(JFd, [], H).

jfd_decode_bits_(JFd, Ds, H) ->
    jfd_decode_bits_(JFd#jfd.bits, H, Ds, JFd).

jfd_decode_bits_(<<0:1,Bits/bits>>, {L,_}, Ds, JFd) ->
    jfd_decode_bits_(Bits, L, [$0|Ds], JFd);
jfd_decode_bits_(<<1:1,Bits/bits>>, {_,R}, Ds, JFd) ->
    jfd_decode_bits_(Bits, R, [$1|Ds], JFd);
jfd_decode_bits_(<<>>, H, Ds, JFd) when is_tuple(H) ->
    JFd1 = jfd_load_bits(JFd#jfd{bits=(<<>>)},8),
    if bit_size(JFd1#jfd.bits) == 0 ->
	    io:format("~s => (<<>>)\n", [reverse(Ds)]),
	    erlang:error({error, not_a_code});
       true ->
	    jfd_decode_bits_(JFd1#jfd.bits, H, Ds, JFd1)
    end;
jfd_decode_bits_(Bits, Code, _Ds, JFd) when is_integer(Code) ->
    %% io:format("~s => ~w\n", [reverse(_Ds), Code]),
    {JFd#jfd {bits=Bits }, Code};
jfd_decode_bits_(Bits, Code, Ds, _JFd) ->
    io:format("~s => ~w (~w)\n", [reverse(Ds), Code, Bits]),
    erlang:error({error, not_a_code}).

%% Byte align the the bit stream (ditch the bits)
jfd_byte_align(JFd) ->
    ?dbg("byte align bits=~w\n", [bit_size(JFd#jfd.bits)]),
    JFd#jfd { bits=(<<>>) }.

%% align the bit stream and read N bytes 
%% return {JFd', Bytes} | {JFd', eof}
jfd_read_bytes(JFd, N) ->
    JFd1 = jfd_byte_align(JFd),
    if N == 0 ->
	    {JFd1, <<>>};
       byte_size(JFd1#jfd.bytes) >= N ->
	    <<X:N/binary, Bytes/binary>> = JFd1#jfd.bytes,
	    {JFd1#jfd { bytes=Bytes }, X};
       true ->
	    JFd2 = jfd_load_bytes(JFd1, 2*N+2),
	    if byte_size(JFd2#jfd.bytes) >= N ->
		    <<X:N/binary, Bytes/binary>> = JFd2#jfd.bytes,
		    {JFd2#jfd { bytes = Bytes }, X};
	       true -> %% can not load M bits so return eof
		    {JFd2, eof}
	    end
    end.

jfd_load_bytes(JFd, N) ->
    case file:read(JFd#jfd.fd, N) of
	{ok,Bin} ->
	    Buf = <<(JFd#jfd.bytes)/binary, Bin/binary>>,
	    JFd#jfd { bytes = Buf };
	eof ->
	    JFd
    end.

%% read N bits
jfd_read_bits(JFd, N) ->
    if
	bit_size(JFd#jfd.bits) >= N ->
	    <<X:N/bits, Bits/bits>> = JFd#jfd.bits,
	    {JFd#jfd { bits=Bits}, X};
	true ->
	    JFd1 = jfd_load_bits(JFd,N),
	    if bit_size(JFd1#jfd.bits) >= N ->
		    <<X:N/bits, Bits/bits>> = JFd1#jfd.bits,
		    {JFd1#jfd { bits=Bits}, X};
	       true ->
		    {JFd1, eof}
	    end
    end.


%% Load at least N bits into bit buffer

jfd_load_bits(JFd, N) ->
    jfd_load_bits_(JFd, JFd#jfd.bits, JFd#jfd.bytes, N).

jfd_load_bits_(JFd, Bits, Bytes, N) ->
    if bit_size(Bits) >= N ->
	    JFd#jfd { bits=Bits, bytes=Bytes };
       true ->
	    case Bytes of
		<<16#FF,16#00,Bytes1/binary>> ->
		    jfd_load_bits_(JFd,<<Bits/bits,16#FF>>,Bytes1,N);
		<<16#FF,B,Bytes1/binary>> ->
		    ?dbg("unstuff: JPEG BUG found marker 16#FF~2.16.0B\n", [B]),
		    jfd_load_bits_(JFd,<<Bits/bits,B>>,Bytes1,N);
		<<16#FF>> ->
		    JFd1 = jfd_load_bytes(JFd#jfd { bytes=Bytes},64),
		    if byte_size(JFd1#jfd.bytes) >= 2 ->
			    jfd_load_bits_(JFd1,Bits,JFd1#jfd.bytes,N);
		       true ->
			    JFd1#jfd { bits=Bits }
		    end;
		<<B,Bytes1/binary>> ->
		    jfd_load_bits_(JFd,<<Bits/bits,B>>,Bytes1,N);
		<<>> ->
		    JFd1 = jfd_load_bytes(JFd#jfd{bytes=(<<>>)},64),
		    if byte_size(JFd1#jfd.bytes) >= 1 ->
			    jfd_load_bits_(JFd1,Bits,JFd1#jfd.bytes,N);
		       true ->
			    JFd1#jfd { bits=Bits }
		    end
	    end
    end.
	

%% decode all DHT tables
decode_dht(<<_:3,AC:1,Ti:4,Bin/binary>>, IMG) ->
    {DHT,Bin1} = epx_huffman:decode_dht(Bin),
    if AC==0 -> 
	    ?dbg("DHT: DC table=~p\n", [Ti]);
       true ->
	    ?dbg("DHT: AC table=~p\n", [Ti])
    end,
    emit_dht(DHT),
    IMG1 = erl_img:set_attribute(IMG, {dht,AC,Ti}, DHT),
    decode_dht(Bin1, IMG1);
decode_dht(<<>>, IMG) ->
    IMG.


%% decode all DQT tables
decode_dqt(<<0:4,Ti:4,Bits/bits>>, IMG) ->
    ?dbg("DQT: Prec=~p,Ti=~p\n",[8,Ti]),
    decode_dqt(8, Ti, 64, Bits, [], IMG);
decode_dqt(<<Prec:4,Ti:4,Bits/bits>>, IMG) ->
    ?dbg("DQT: Prec=~p,Ti=~p\n",[Prec+1,Ti]),
    decode_dqt(Prec+1, Ti, 64, Bits, [], IMG);
decode_dqt(<<>>, IMG) ->
    IMG.

decode_dqt(_Len, Ti, 0, Bits, Acc, IMG) ->
    DQT = reverse(Acc),
    ?dbg("DQT: Table ~w\n", [Ti]), emit_8x8(DQT),
    IMG1 = erl_img:set_attribute(IMG, {dqt,Ti}, DQT),
    decode_dqt(Bits, IMG1);
decode_dqt(Len, Ti, I, Bits, Acc, IMG) ->
    <<V:Len,Bits1/bits>> = Bits,
    decode_dqt(Len, Ti, I-1, Bits1, [V|Acc], IMG).

dequantize([C|Cs], [Q|Qs]) ->
    [C*Q | dequantize(Cs, Qs)];
dequantize([], []) ->
    [].

quantize([C|Cs], [Q|Qs]) ->
    [trunc((C / Q)+0.5) | quantize(Cs, Qs)];
quantize([], []) ->
    [].
    

%%
%% JPEG Block A[64] (or A[8][8])  encoded as:
%%   0. Coefficent A[0] (DC) is coded with difference endcoding
%%   1. Rest of A is coded with RLC  (run length encoding) as:
%%      [ {N1,Byte1}, {N2,Byte2} ... {Nk,Bytek} ] where
%%        Ni is the number of zeros proceeding the Bytei
%%      {0,0} is special and mark end of block (if block is ending with zeros!)
%%        Ni < 16!
%%      {15,0} is special and means 16 zeros!!!
%%
%%   2. Each Bytei is then converted into {NBits,Bits}
%%      where NBits (category) is the smallest number used to represent the Byte
%%      Negative numbers are one complemented
%%
%%   3. Huffman encode the byte code <<Ni:4,NBits:4>> and store the
%%      bits followed by  <<Bits:NBits>>
%%

category_encode(X) when X < 0 ->
    N = nbits(-X),
    {N, (bnot (-X)) band ((1 bsl N)-1)};
category_encode(X) when X > 0 ->
    N = nbits(X),
    {N, X}.

%% determine number of bits (< 16) needed to represent X
nbits(X) when X > 16#ff, X =< 16#7fff -> nbits8(X bsr 8, 8);
nbits(X) when X > 0, X =< 16#7fff -> nbits8(X, 0).

nbits8(X, N) when X > 16#f -> nbits4(X bsr 4, N+4);
nbits8(X, N) -> nbits4(X, N).

nbits4(X, N) when X > 16#3 -> nbits2(X bsr 2, N+2);
nbits4(X, N) -> nbits2(X, N).

nbits2(0, N) -> N;
nbits2(1, N) -> N+1;
nbits2(2, N) -> N+2;
nbits2(3, N) -> N+2.

category_decode(N,V) ->
    if V band (1 bsl (N-1)) == 0 ->
	    -((bnot V) band ((1 bsl N) - 1));
       true  ->
	    V
    end.

%% decode 64 DCT valus
decode_block(JFd, Dc0, C) ->
    %% Handle DC  A[0]
    {JFd1,N} = jfd_decode_bits(JFd,C#comp.dcd),
    {JFd2, <<V:N>>} = jfd_read_bits(JFd1,N),
    Diff = category_decode(N,V),
    %% ?dbg("DC: Diff=~p, DC=~p\n", [Diff,Dc0+Diff]),
    %% Handle AC  A[1..63]
    decode_block_ac(JFd2, 63, [Dc0 + Diff], C).

decode_block_ac(JFd, 0, Acs, _C) ->
    {JFd, reverse(Acs)};
decode_block_ac(JFd, I, Acs, C) when I > 0 ->
    {JFd1,V} = jfd_decode_bits(JFd,C#comp.acd),
    S = V band 16#f,          %% size
    R = (V bsr 4) band 16#f,  %% run length
    if
	S == 0 ->
	    if 
		R == 0 ->
		    decode_eob(JFd1, I, Acs);
		R == 15 ->
		    Z1 = min(I, 16),
		    Acs1 = cat_zeros(Z1, Acs),
		    decode_block_ac(JFd1, I-Z1, Acs1, C);
		R > I ->
		    ?dbg("JPEG BUG R=~w >= I=~w!!!\n", [R,I]),
		    Acs1 = cat_zeros(I, Acs),
		    decode_block_ac(JFd1, 0, Acs1, C);
	       true ->
		    ?dbg("JPEG BUG R=~w >= I=~w!!!\n", [R,I]),
		    Acs1 = cat_zeros(R, Acs),
		    decode_block_ac(JFd1, I-R, Acs1, C)
	    end;
       R >= I ->
	    ?dbg("JPEG BUG: R=~w >= I=~w, S = ~w!!!\n", [R,I,S]),
	    Acs1 = cat_zeros(I, Acs),
	    decode_block_ac(JFd1, 0, Acs1, C);
       true ->
	    %% ?dbg("(~w,~w)\n", [R,S]),
	    Acs1 = cat_zeros(R, Acs),
	    {JFd2,<<Y:S>>} = jfd_read_bits(JFd1,S),
	    X = category_decode(S,Y),
	    decode_block_ac(JFd2, (I-R)-1, [X|Acs1], C)
    end.

cat_zeros(0, Acs) -> Acs;
cat_zeros(I, Acs) -> cat_zeros(I-1, [0|Acs]).

decode_eob(JFd,0,Acs) ->
    {JFd, reverse(Acs)};
decode_eob(JFd,I,Acs) ->
    decode_eob(JFd,I-1,[0|Acs]).


%% Start Of Frame
process_sofn(_M,<<Depth:8,Height:16,Width:16,NComp:8,Bin/binary>>, IMG) ->
    ?dbg("SOF(~p), Depth=~p, Height=~p, Width=~p, Components=~p\n",
	 [_M-?M_SOF0,Depth,Height,Width,NComp]),
    %% Depth: typically 8.. (12,16)
    IMG1 = IMG#erl_image { depth=Depth, height=Height,width=Width },
    process_sofn_component(NComp,Bin, IMG1).

component_id(1) -> y;  %% lumincance
component_id(2) -> cb; %% 
component_id(3) -> cr; %% 
component_id(4) -> i;  %%
component_id(5) -> q.  %%
    
process_sofn_component(0, _Bin, IMG) ->
    IMG;
process_sofn_component(I, <<ID:8,H:4,V:4,Q:8,Bin/binary>>,IMG) ->
    Format = component_id(ID),
    IMG1 = erl_img:set_attribute(IMG, {component,Format}, {Q,H,V}),
    ?dbg("component ~p q=~p, h=~p, v=~p\n", [Format,Q,H,V]),
    process_sofn_component(I-1, Bin, IMG1).
    

%% Maker OLYMP
collect_olymp(_Fd, _T, St) ->
    ?dbg("OLYMP(~s) ~4.16.0B ~p ~p\n", 
	 [_T#tiff_entry.ifd,_T#tiff_entry.tag,
	  _T#tiff_entry.type, _T#tiff_entry.value]),
    St.

%% Maker Nikon
collect_nikon(_Fd, _T, St) ->
    ?dbg("Nikon(~s) ~4.16.0B ~p ~p\n", 
	[_T#tiff_entry.ifd,_T#tiff_entry.tag,
	 _T#tiff_entry.type, _T#tiff_entry.value]),
    St.

%% Maker FUJIFILM
collect_fujifilm(_Fd, _T, St) ->
    ?dbg("Fujifilm(~s) ~4.16.0B ~p ~p\n", 
	 [_T#tiff_entry.ifd,_T#tiff_entry.tag,
	  _T#tiff_entry.type,_T#tiff_entry.value]),
    St.

%% Maker Sony DSC
collect_sony(_Fd, _T, St) ->
    ?dbg("Sony(~s) ~4.16.0B ~p ~p\n", 
	 [_T#tiff_entry.ifd,_T#tiff_entry.tag,
	  _T#tiff_entry.type,_T#tiff_entry.value]),
    St.    

%% Maker other
collect_other(_Fd, _T, St) ->
    ?dbg("Maker(~s) ~4.16.0B ~p ~p\n", 
	 [_T#tiff_entry.ifd,_T#tiff_entry.tag,
	  _T#tiff_entry.type,_T#tiff_entry.value]),
    St.

collect_maker(_Fd, _T, St) ->
    {ok, St}.

collect_maker_fixme(Fd, T, St) ->
    ?dbg("Tif entry=~p\n", [T]),
    MakerBin = T#tiff_entry.value,
    case MakerBin of
	<<"OLYMP",0,1,0,_/binary>> ->
	    image_tiff:scan_ifd(Fd,
			     [$0,$:|T#tiff_entry.ifd],
			     T#tiff_entry.offs+8,
			     T#tiff_entry.endian,
			     fun collect_olymp/3, St);
	<<"Nikon",0,1,0,_/binary>> ->
	    image_tiff:scan_ifd(Fd,
			     [$0,$:|T#tiff_entry.ifd],
			     T#tiff_entry.offs+8,
			     T#tiff_entry.endian,
			     fun collect_nikon/3, St);
	<<"SONY DSC ",0,0,0,_/binary>> ->
	    %% NOT working - what is SONY doing ?
	    image_tiff:scan_ifd(Fd,
			     [$0,$:|T#tiff_entry.ifd],
			     T#tiff_entry.offs+14,
			     T#tiff_entry.endian,
			     fun collect_sony/3, St);
	<<"FUJIFILM",Offset:32/little>> ->
	    image_tiff:scan_ifd_bin(MakerBin, 
				 [$0,$:|T#tiff_entry.ifd],
				 Offset, little,
				 fun collect_fujifilm/3, St);
	_ ->
	    image_tiff:scan_ifd(Fd,
			     [$0,$:|T#tiff_entry.ifd],
			     T#tiff_entry.offs+8,
			     T#tiff_entry.endian,
			     fun collect_other/3, St)
    end.


collect_exif(Fd, T, St) ->
    ?dbg("EXIF(~s) ~p ~p ~p\n", 
	[T#tiff_entry.ifd,
	 exif:decode_tag(T#tiff_entry.tag),
	 T#tiff_entry.type, T#tiff_entry.value]),
    case T#tiff_entry.tag of
	?ExifInteroperabilityOffset ->
	    [Offset] = T#tiff_entry.value,
	    %% could be handle by a collect_interop?
	    case image_tiff:scan_ifd(Fd, [$0,$.|T#tiff_entry.ifd],
				  Offset, T#tiff_entry.endian,
				  fun collect_exif/3, St) of
		{ok, St1} ->
		    St1;
		_Error ->
		    St
	    end;
	?MakerNote ->
	    case collect_maker(Fd, T, St) of
		{ok,St1} ->
		    St1;
		_Error ->
		    St
	    end;
	_ ->
	    St
    end.


%% Image info collector functions
collect_tiff(Fd, T, St) ->
    Key = image_tiff:decode_tag(T#tiff_entry.tag),
    ?dbg("TIFF(~s) ~p ~p ~p\n", 
	[T#tiff_entry.ifd,Key,T#tiff_entry.type, T#tiff_entry.value]),
    case T#tiff_entry.tag of
	?ImageWidth ->
	    [Width] = T#tiff_entry.value,
	    St#erl_image { width = Width };
	?ImageLength ->
	    [Length] = T#tiff_entry.value,
	    St#erl_image { height = Length };
	?BitsPerSample ->
	    Bs = T#tiff_entry.value,
	    St#erl_image { depth = lists:sum(Bs) };
	?ImageDescription ->
	    [Value] = T#tiff_entry.value,
	    St#erl_image { comment = Value };
	?DateTime ->
	    [Value] = T#tiff_entry.value,
	    case string:tokens(Value, ": ") of
		[YYYY,MM,DD,H,M,S] ->
		    DateTime = {{list_to_integer(YYYY),
				 list_to_integer(MM),
				 list_to_integer(DD)},
				{list_to_integer(H),
				 list_to_integer(M),
				 list_to_integer(S)}},
		    St#erl_image { itime = DateTime};
		_ ->
		    St
	    end;
	?ExifOffset ->
	    [Offset] = T#tiff_entry.value,
	    case image_tiff:scan_ifd(Fd, [$0,$.|T#tiff_entry.ifd],
				  Offset, T#tiff_entry.endian,
				  fun collect_exif/3, St) of
		{ok, St1} ->
		    St1;
		_Error ->
		    St
	    end;
	_ ->
	    Value = T#tiff_entry.value,
	    As = St#erl_image.attributes,
	    St#erl_image { attributes = [{Key,Value}|As]}
    end.

process_jfif(Bin, IMG) ->
    case Bin of
	<<_Version:16,_Units:8,
	 _Xdensity:16, _Ydensity:16,
	 _Xthumbnail:8, _Ythumbnail:8,_RGB/binary>> ->
	    IMG;
	_ ->
	    IMG
    end.

process_exif(Bin, IMG) ->
    case image_tiff:scan_binary(Bin, fun collect_tiff/3, IMG) of
	{ok, IMG1} ->
	    IMG1;
	_Error ->
	    IMG
    end.


%%
%% Rezigag & convert to matrix from
%%

rzigzag([A0, A1, A8,A16, A9, A2, A3,A10,
	 A17,A24,A32,A25,A18,A11,A4,A5,
	 A12,A19,A26,A33,A40,A48,A41,A34,
	 A27,A20,A13, A6, A7,A14,A21,A28,
	 A35,A42,A49,A56,A57,A50,A43,A36,
	 A29,A22,A15,A23,A30,A37,A44,A51,
	 A58,A59,A52,A45,A38,A31,A39,A46,
	 A53,A60,A61,A54,A47,A55,A62,A63]) ->
    [[A0, A1, A2, A3, A4, A5, A6, A7], 
     [A8, A9, A10,A11,A12,A13,A14,A15],
     [A16,A17,A18,A19,A20,A21,A22,A23],
     [A24,A25,A26,A27,A28,A29,A30,A31],
     [A32,A33,A34,A35,A36,A37,A38,A39],
     [A40,A41,A42,A43,A44,A45,A46,A47],
     [A48,A49,A50,A51,A52,A53,A54,A55],
     [A56,A57,A58,A59,A60,A61,A62,A63]].

%%
%% Conver from 8x8 matrix form to block mode
%%
zigzag([[A0, A1, A5, A6,A14,A15,A27,A28],
	[A2, A4, A7,A13,A16,A26,A29,A42],
	[A3, A8,A12,A17,A25,A30,A41,A43],
	[A9,A11,A18,A24,A31,A40,A44,A53],
	[A10,A19,A23,A32,A39,A45,A52,A54],
	[A20,A22,A33,A38,A46,A51,A55,A60],
	[A21,A34,A37,A47,A50,A56,A59,A61],
	[A35,A36,A48,A49,A57,A58,A62,A63]]) ->
    [A0, A1, A2, A3, A4, A5, A6, A7, 
     A8, A9, A10,A11,A12,A13,A14,A15,
     A16,A17,A18,A19,A20,A21,A22,A23,
     A24,A25,A26,A27,A28,A29,A30,A31,
     A32,A33,A34,A35,A36,A37,A38,A39,
     A40,A41,A42,A43,A44,A45,A46,A47,
     A48,A49,A50,A51,A52,A53,A54,A55,
     A56,A57,A58,A59,A60,A61,A62,A63].
    



%%
%% Map fun over 0..N-1
%% or over Start I+Step Stop
%%

formap(N, Fun) ->
    formap(0, N, 1, Fun).

formap(Start, Stop, Step, Fun) when 
  is_integer(Start),is_integer(Stop),is_integer(Step),
  is_function(Fun) ->
    if Step > 0, Start < Stop ->
	    formap_inc(Start,Stop,Step,Fun);
       Step < 0, Start > Stop ->
	    formap_dec(Start,Stop,-Step,Fun);
       true ->
	    []
    end.

formap_inc(I, N, S, Fun) when I < N ->
    [Fun(I) | formap_inc(I+S, N, S, Fun)];
formap_inc(_I,_N,_S,_Fun) ->
    [].

formap_dec(I, N, S, Fun) when I > N ->
    [Fun(I) |formap_dec(I-S, N, S, Fun)];
formap_dec(_I,_N,_S,_Fun) ->
    [].

%%
%% For loop construction
%% for (N, fun(I,Acc) -> ... end, Acc0) -> AccN.
%% for (Start, Stop, Step, fun(I,Acc) -> ... end, Acc0) -> AccN.
%%
forfold(N, Fun, Acc) ->
    forfold(0, N, 1, Fun, Acc).

forfold(Start, Stop, Step, Fun, Acc) when 
  is_integer(Start),is_integer(Stop),is_integer(Step),
  is_function(Fun) ->
    if Step > 0, Start < Stop ->
	    forfold_inc(Start,Stop,Step,Fun,Acc);
       Step < 0, Start > Stop ->
	    forfold_dec(Start,Stop,-Step,Fun,Acc);
       true ->
	    Acc
    end.

forfold_inc(I, N, S, Fun, Acc) when I < N ->
    forfold_inc(I+S, N, S, Fun, Fun(I, Acc));
forfold_inc(_I,_N,_S,_Fun,Acc) ->
    Acc.

forfold_dec(I, N, S, Fun, Acc) when I > N ->
    forfold_dec(I-S, N, S, Fun, Fun(I, Acc));
forfold_dec(_I,_N,_S,_Fun,Acc) ->
    Acc.

%%
%%
%% Debug stuff
%%

%% print record
emit_record(R, Fs) ->    
    io:format("#~s {", [element(1, R)]),
    emit_fields(2, R, Fs),
    io:format("}.\n", []).

emit_fields(I, R, [F]) ->
    io:format("  ~s = ~w\n", [F, element(I,R)]);
emit_fields(I, R, [F|Fs]) ->
    io:format("  ~s = ~w,\n", [F, element(I,R)]),
    emit_fields(I+1, R, Fs);
emit_fields(_I, _R, []) ->
    ok.

%% emit 8x8 matrix like format
emit_8x8(DQT) ->
    emit_8x8(DQT,"~w").

emit_8x8(DQT, Fmt) ->
    L1 = lists:map(fun(E) -> io_lib:format(Fmt, [E]) end, DQT),
    En = lists:max(lists:map(fun(F) -> iolist_size(F) end, L1)),
    Fmt2 = "~"++integer_to_list(En)++"s",
    
    io:format("[", []), emit_es(L1,Fmt2,0), io:format("]\n", []).

emit_es([E],Fmt,_) ->
    io:format(Fmt, [E]);
emit_es([E|Es],Fmt,I) when I > 0, I rem 8 == 0 ->
    io:format("\n "++Fmt++",", [E]),
    emit_es(Es,Fmt,I+1);
emit_es([E|Es],Fmt,I) ->
    io:format(Fmt++",", [E]),
    emit_es(Es,Fmt,I+1).


%% emit huffman decoder
%%   bitseq => value
emit_dht(DHT) ->
    emit_ht(DHT,[]).

emit_ht(x, _Ds) ->  %% not used
    ok;
emit_ht(Code, Ds) when is_integer(Code) ->
    io:format("<<2#~s:~w,Bs/bits>> -> ~w;\n", [reverse(Ds), length(Ds), Code]);
emit_ht({L,R}, Ds) ->
    emit_ht(L, [$0|Ds]),
    emit_ht(R, [$1|Ds]).

%% print bits
format_bits(Bits) ->
    [Bit+$0 || <<Bit:1>> <= Bits]. 
