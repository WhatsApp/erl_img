-ifndef(__IMAGE_JPG_HRL__).
-define(__IMAGE_JPG_HRL__, true).

-define(M_MARK, 16#FF).

-define(M_SOF0, 16#C0).      %% Start Of Frame N
-define(M_SOF1, 16#C1).      %% N indicates which compression process
-define(M_SOF2, 16#C2).      %% Only SOF0-SOF2 are now in common use
-define(M_SOF3, 16#C3).
-define(M_SOF5, 16#C5).      %% NB: codes C4 and CC are NOT SOF markers
-define(M_SOF6, 16#C6).
-define(M_SOF7, 16#C7).
-define(M_SOF9, 16#C9).
-define(M_SOF10,16#CA).
-define(M_SOF11,16#CB).
-define(M_SOF13,16#CD).
-define(M_SOF14,16#CE).
-define(M_SOF15,16#CF).
-define(M_DHT,  16#C4).
-define(M_RST0, 16#D0).
-define(M_SOI,  16#D8).       %% Start Of Image (beginning of datastream)
-define(M_EOI,  16#D9).       %% End Of Image (end of datastream)
-define(M_SOS,  16#DA).       %% Start Of Scan (begins compressed data)
-define(M_DQT,  16#DB).
-define(M_DRI,  16#DD).
-define(M_JFIF, 16#E0).       %% Jfif marker
-define(M_EXIF, 16#E1).       %% Exif marker
-define(M_COM,  16#FE).       %% COMment 

-endif.


