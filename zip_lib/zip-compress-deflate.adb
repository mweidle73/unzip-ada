-- The "Deflate" method combines the LZ77 compression method with some Huffman
-- encoding gymnastics.
--
-- See package specification for details.
--
-- Change log:
--
-- 20-Feb-2016: (rev.305) Start of (hopefully) smarter techniques for "Dynamic" encoding (Taillaule algorithm)
--  4-Feb-2016: Start of "Dynamic" encoding format (compression structure sent before block)
-- 19-Feb-2011: All distance and length codes implemented.
-- 18-Feb-2011: First version working with Deflate fixed and restricted
--                distance & length codes.
-- 17-Feb-2011: Created.

with Zip.LZ77, Zip.CRC_Crypto;
with Zip_Streams;

with Length_limited_Huffman_code_lengths;

with Ada.Exceptions;                    use Ada.Exceptions;
with Interfaces;                        use Interfaces;
with Ada.Text_IO;                       use Ada.Text_IO;

procedure Zip.Compress.Deflate
 (input,
  output          : in out Zip_Streams.Root_Zipstream_Type'Class;
  input_size_known: Boolean;
  input_size      : File_size_type;
  feedback        : Feedback_proc;
  method          : Deflation_Method;
  CRC             : in out Interfaces.Unsigned_32; -- only updated here
  crypto          : in out Crypto_pack;
  output_size     : out File_size_type;
  compression_ok  : out Boolean -- indicates compressed < uncompressed
)
is
  use Zip_Streams;

  trace    : constant Boolean:= True;
  log      : File_Type;
  log_name : constant String:= "Zip.Compress.Deflate.csv";
  sep      : constant Character:= ';';

  ------------------
  -- Buffered I/O --
  ------------------

  --  Define data types needed to implement input and output file buffers

  InBuf, OutBuf: Byte_Buffer(1..buffer_size);

  InBufIdx: Positive;  --  Points to next char in buffer to be read
  OutBufIdx: Positive; --  Points to next free space in output buffer

  MaxInBufIdx: Natural;  --  Count of valid chars in input buffer
  InputEoF: Boolean;     --  End of file indicator

  procedure Read_Block is
  begin
    Zip.BlockRead(
      stream        => input,
      buffer        => InBuf,
      actually_read => MaxInBufIdx
    );
    InputEoF:= MaxInBufIdx = 0;
    InBufIdx := 1;
  end Read_Block;

  -- Exception for the case where compression works but produces
  -- a bigger file than the file to be compressed (data is too "random").
  Compression_unefficient: exception;

  procedure Write_Block is
    amount: constant Integer:= OutBufIdx-1;
  begin
    output_size:= output_size + File_size_type(Integer'Max(0,amount));
    if input_size_known and then output_size >= input_size then
      -- The compression so far is obviously inefficient for that file.
      -- Useless to go further.
      -- Stop immediately before growing the file more than the
      -- uncompressed size.
      raise Compression_unefficient;
    end if;
    Encode(crypto, OutBuf(1 .. amount));
    Zip.BlockWrite(output, OutBuf(1 .. amount));
    OutBufIdx := 1;
  end Write_Block;

  procedure Put_byte(B : Byte) is  --  Put a byte, at the byte granularity level
  begin
    OutBuf(OutBufIdx) := B;
    OutBufIdx:= OutBufIdx + 1;
    if OutBufIdx > OutBuf'Last then
      Write_Block;
    end if;
  end Put_byte;

  --------------------------------------------------------------------------

  ------------------------------------------------------
  --  Bit code buffer, for sending data at bit level  --
  ------------------------------------------------------

  Save_byte: Byte;  --  Output code buffer
  Bits_used: Byte;  --  Index into output code buffer

  procedure Flush_bit_output is
  begin
    if Bits_used /= 0 then
      Put_byte(Save_byte);
    end if;
    if OutBufIdx > 1 then
      Write_Block;
    end if;
  end Flush_bit_output;

  type U32 is mod 2**32;

  procedure Put_code(code: U32; code_size: Natural) is
    code_work: U32:= code;
    temp, Save_byte_local, Bits_used_local: Byte;
  begin
    temp:= 0;
    Save_byte_local:= Save_byte;
    Bits_used_local:= Bits_used;
    for count in reverse 1 .. code_size loop
      temp:= 0;
      if code_work mod 2 = 1 then
        temp:= temp + 1;
      end if;
      code_work:= code_work  / 2;
      temp:= Shift_Left(temp, Integer(Bits_used_local));
      Bits_used_local:= Bits_used_local+1;
      Save_byte_local:= Save_byte_local or temp;
      if Bits_used_local = 8 then
        Put_byte(Save_byte_local);
        Save_byte_local:= 0;
        temp:= 0;
        Bits_used_local:= 0;
      end if;
    end loop;
    Save_byte:= Save_byte_local;
    Bits_used:= Bits_used_local;
  end Put_code;

  --------------------------------
  -- LZ77 front-end compression --
  --------------------------------

  procedure Encode is

    X_Percent: Natural;
    Bytes_in   : Natural;   --  Count of input file bytes processed
    user_aborting: Boolean;
    PctDone: Natural;

    function Read_byte return Byte is
      b: Byte;
    begin
      b:= InBuf(InBufIdx);
      InBufIdx:= InBufIdx + 1;
      Zip.CRC_Crypto.Update(CRC, (1=> b));
      Bytes_in:= Bytes_in + 1;
      if feedback /= null then
        if Bytes_in = 1 then
          feedback(0, False, user_aborting);
        end if;
        if X_Percent > 0 and then
           ((Bytes_in-1) mod X_Percent = 0
            or Bytes_in = Integer(input_size))
        then
          if input_size_known then
            PctDone := Integer( (100.0 * Float( Bytes_in)) / Float(input_size));
            feedback(PctDone, False, user_aborting);
          else
            feedback(0, False, user_aborting);
          end if;
          if user_aborting then
            raise User_abort;
          end if;
        end if;
      end if;
      return b;
    end Read_byte;

    function More_bytes return Boolean is
    begin
      if InBufIdx > MaxInBufIdx then
        Read_Block;
      end if;
      return not InputEoF;
    end More_bytes;

    -- LZ77 params
    Look_Ahead         : constant Integer:= 258;
    String_buffer_size : constant := 2**15;  --  Required: 2**15 for Deflate, 2**16 for Deflate_e
    Threshold          : constant := 2;

    --  If the DLE coding doesn't fit the format constraints, we need
    --  to decode it as a simple sequence of literals. The buffer used is
    --  called "Text" buffer by reference to "clear-text", but actually it
    --  is any binary data.

    type Text_buffer_index is mod String_buffer_size;
    type Text_buffer is array ( Text_buffer_index ) of Byte;
    Text_Buf: Text_Buffer;
    R: Text_buffer_index;

    ------------------------------------------------------
    -- Deflate, post LZ encoding, with Huffman encoding --
    ------------------------------------------------------

    invalid: constant:= -1;

    subtype Huffman_code_range is Integer range invalid .. Integer'Last;

    type Length_code_pair is record
      length : Natural;                       --  Huffman code length, in bits
      code   : Huffman_code_range:= invalid;  --  The code itself
    end record;

    procedure Invert(lc: in out Length_code_pair) is
    pragma Inline(Invert);
      a: Natural:= lc.code;
      b: Natural:= 0;
    begin
      for i in 1..lc.length loop
        b:= b * 2 + a mod 2;
        a:= a / 2;
      end loop;
      lc.code:= b;
    end Invert;

    --  The Huffman code set (and therefore the Huffman tree) is completely determined by
    --  the bit length to be used for reaching leaf nodes, thanks to two special
    --  rules (See RFC 1951, section 3.2.2).
    --
    --  So basically the process is the following:
    --
    --  A) Gather statistics (just counts) for the alphabet
    --  B) Turn these counts into code lengths, with a call to Length_limited_Huffman_code_lengths
    --  C) Build Huffman codes (the bits to be sent) with a call to Prepare_codes

    type Huff_descriptor is array(Natural range <>) of Length_code_pair;

    type Deflate_Huff_descriptors is record
      --  Tree descriptor for Literal, EOB or Length encoding
      lit_len: Huff_descriptor(0..287);
      --  Tree descriptor for Distance encoding
      dis: Huff_descriptor(0..31);
    end record;
    --  Appnote: Literal codes 286-287 and distance codes 30-31 are never used
    --  but participate in the huffman construction.
    --  GdM: setting upper bound to 285 for literals leads to invalid codes, sometimes.
    
    --  The Prepare_codes function finds the Huffman code for each value, given
    --  the bit length imposed as input.
    procedure Prepare_codes(hd: in out Huff_descriptor) is
      max_huffman_bits: constant:= 15;
      bl_count, next_code: array(0..max_huffman_bits) of Natural:= (others => 0);
      code: Natural:= 0;
      bl: Natural;
    begin
      --  Algorithm from RFC 1951, section 3.2.2.
      --  Step 1)
      for i in hd'Range loop
        bl:= hd(i).length;
        bl_count(bl):= bl_count(bl) + 1;  --  One more code to be defined with bit length bl
      end loop;
      --  Step 2)
      for bits in 1 .. max_huffman_bits loop
        code:= (code + bl_count(bits-1)) * 2;
        next_code(bits):= code;  --  This will be the first code for bit length "bits"
      end loop;
      --  Step 3)
      for n in hd'Range loop
        bl:= hd(n).length;
        if bl > 0 then
          hd(n).code:= next_code(bl);
          next_code(bl):= next_code(bl) + 1;
        else
          hd(n).code:= 0;
        end if;
      end loop;
      --  Invert bit order for output:
      for i in hd'Range loop
        Invert(hd(i));
      end loop;
    end Prepare_codes;

    function Prepare_Huffman_codes(dhd: Deflate_Huff_descriptors) return Deflate_Huff_descriptors
    is
      dhd_var: Deflate_Huff_descriptors:= dhd;
    begin
      Prepare_codes(dhd_var.lit_len);
      Prepare_codes(dhd_var.dis);
      return dhd_var;
    end Prepare_Huffman_codes;

    ------------------------------
    --  Compression structures  --
    ------------------------------

    type Bit_length_array is array(Natural range <>) of Natural;
    subtype Alphabet_lit_len is Natural range 0..287;
    subtype Bit_length_array_lit_len is Bit_length_array(Alphabet_lit_len);
    subtype Alphabet_dis is Natural range 0..31;
    subtype Bit_length_array_dis is Bit_length_array(Alphabet_dis);

    function Build_descriptors(
      bl_for_lit_len : Bit_length_array_lit_len;
      bl_for_dis     : Bit_length_array_dis
    )
    return Deflate_Huff_descriptors
    is
      new_d: Deflate_Huff_descriptors;
    begin
      for i in new_d.lit_len'Range loop
        new_d.lit_len(i):= (length => bl_for_lit_len(i), code => invalid);
        if trace then
          Put(log, Integer'Image(bl_for_lit_len(i)) & sep);
        end if;
      end loop;
      for i in new_d.dis'Range loop
        new_d.dis(i):= (length => bl_for_dis(i), code => invalid);
        if trace then
          Put(log, Integer'Image(bl_for_dis(i)) & sep);
        end if;
      end loop;
      if trace then
        New_Line(log);
      end if;
      return Prepare_Huffman_codes(new_d);
    end Build_descriptors;

    type Count_type is range 0..File_size_type'Last/2-1;
    type Stats_lit_len_type is array(Alphabet_lit_len) of Count_type;
    type Stats_dis_type is array(Alphabet_dis) of Count_type;

    --  Do the phases A) B) C) in one go.
    function Build_descriptors(stats_lit_len: Stats_lit_len_type; stats_dis_0: Stats_dis_type)
    return Deflate_Huff_descriptors
    is
      bl_for_lit_len : Bit_length_array_lit_len;
      bl_for_dis     : Bit_length_array_dis;
      procedure LLHCL_lit_len is new
        Length_limited_Huffman_code_lengths(
          Alphabet_lit_len, Count_type, Stats_lit_len_type, Bit_length_array_lit_len, 15
        );
      procedure LLHCL_dis is new
        Length_limited_Huffman_code_lengths(
          Alphabet_dis, Count_type, Stats_dis_type, Bit_length_array_dis, 15
        );
      stats_dis     : Stats_dis_type:= stats_dis_0;
      used          : Natural:= 0;
    begin
      --  See "PatchDistanceCodesForBuggyDecoders" in Zopfli's deflate.c
      --  NB: here, we patch the occurrences and not the bit lengths, to avoid invalid codes.
      --  The decoding bug concerns Zlib v.<= 1.2.1, UnZip v.<= 6.0, WinZip v.10.0.
      for i in stats_dis'Range loop
        if stats_dis(i) /= 0 then
          used:= used + 1;
        end if;
      end loop;
      if used < 2 then
        if used = 0 then  --  No distance code used at all (data must be almost random)
          stats_dis(0) := 1;
          stats_dis(1) := 1;
        elsif stats_dis(0) = 0 then
          stats_dis(0) := 1;  --  now code 0 and some other code have non-zero counts
        else
          stats_dis(1) := 1;  --  now codes 0 and 1 have non-zero counts
        end if;
      end if;
      LLHCL_lit_len(stats_lit_len, bl_for_lit_len);  --  Call the magic algorithm for setting
      LLHCL_dis(stats_dis, bl_for_dis);              --    up Huffman lengths of both trees
      return Build_descriptors(bl_for_lit_len, bl_for_dis);
    end Build_descriptors;

    End_Of_Block: constant:= 256;

    --  Default Huffman trees, for "fixed" blocks, as defined in appnote.txt or RFC 1951

    default_lit_len_bl: constant Bit_length_array_lit_len:=
      (  0 .. 143   => 8,  --  For literals ("plain text" bytes)
       144 .. 255   => 9,  --  For more literals ("plain text" bytes)
       End_Of_Block => 7,  --  For EOB (256)
       257 .. 279   => 7,  --  For length codes
       280 .. 287   => 8   --  For more length codes
      );
    default_dis_bl: constant Bit_length_array_dis:= (others => 5);

    Deflate_fixed_descriptors: constant Deflate_Huff_descriptors:=
      Build_descriptors( default_lit_len_bl, default_dis_bl);

    random_data_lit_len: constant Stats_lit_len_type:=
      (0 .. 255     => 30000,
       End_Of_Block => 1,
       others       => 0);  --  No length code used, because no repeated slice, because random
    random_data_dis: constant Stats_dis_type:=
      (others => 0);  --  No distance code used, because no repeated slice, because random

    random_data_descriptors: constant Deflate_Huff_descriptors:=
      Build_descriptors( random_data_lit_len, random_data_dis);

    --  Here is the original part in the Taillaule algorithm: use of
    --  basic topology (metric spaces).
    
    --  L1 or Manhattan distance
    function L1_distance(h1, h2: Deflate_Huff_descriptors) return Natural is
      s: Natural:= 0;
    begin
      for i in h1.lit_len'Range loop
        s:= s + abs(h1.lit_len(i).length - h2.lit_len(i).length);
      end loop;
      for i in h1.dis'Range loop
        s:= s + abs(h1.dis(i).length - h2.dis(i).length);
      end loop;
      return s;
    end L1_distance;

    --  L2 or Euclidean distance
    function L2_distance_square(h1, h2: Deflate_Huff_descriptors) return Natural is
      s: Natural:= 0;
    begin
      for i in h1.lit_len'Range loop
        s:= s + (h1.lit_len(i).length - h2.lit_len(i).length) ** 2;
      end loop;
      for i in h1.dis'Range loop
        s:= s + (h1.dis(i).length - h2.dis(i).length) ** 2;
      end loop;
      return s;
    end L2_distance_square;

    type Distance_type is (L1, L2);

    function Similar(
      h1, h2    : Deflate_Huff_descriptors;
      dist_kind : Distance_type;
      threshold : Natural;
      comment   : String
    )
    return Boolean is
      dist  : Natural;
      thres : Natural:= threshold;
    begin
      case dist_kind is
        when L1 =>
          dist:= L1_distance(h1,h2);
        when L2 =>
          thres := thres * thres;
          dist  := L2_distance_square(h1,h2);
      end case;
      if trace then
        Put_Line(log, 
          "Checking similarity" & sep & sep & sep & sep & sep & 
          Distance_type'Image(dist_kind) & sep &
          "Distance (ev. **2):" & sep & sep & sep & sep & Integer'Image(dist) & sep & sep &
          "Threshold (ev. **2):" & sep & sep & Integer'Image(thres) & sep & sep &
          comment
        );
      end if;
      return dist < thres;
    end Similar;

    function Recyclable(h_old, h_new: Deflate_Huff_descriptors) return Boolean is
    begin
      for i in h_old.lit_len'Range loop
        if h_old.lit_len(i).length = 0 and h_new.lit_len(i).length > 0 then
          return False;  --  Code used in new but not in old
        end if;
      end loop;
      for i in h_old.dis'Range loop
        if h_old.dis(i).length = 0 and h_new.dis(i).length > 0 then
          return False;  --  Code used in new but not in old
        end if;
      end loop;
      return True;      
    end Recyclable;
    
    --  Emit a Huffman code
    procedure Put_code(lc: Length_code_pair) is
    begin
      if lc.length = 0 then
        Raise_Exception(Constraint_Error'Identity, "Huffman code of length 0 should not occurr");
      end if;
      Put_code(U32(lc.code), lc.length);
    end Put_code;

    --  This is where the "dynamic" Huffman trees are sent before the block's data are sent.
    --  The decoder needs to know the tree pair for decoding the data.
    --  But this information takes some room. Fortunately Deflate allows for compressing it
    --  with both Huffman and Run-Length (RLE) encoding.
    procedure Put_compression_structure(dhd: Deflate_Huff_descriptors) is
      subtype Alphabet is Integer range 0..18;
      type Alpha_Array is new Bit_length_array(Alphabet);
      truc_freq, truc_bl: Alpha_Array;
      truc: Huff_descriptor(Alphabet);
      max_used_lln_code: Alphabet_lit_len:= 0;
      max_used_dis_code: Alphabet_dis:= 0;
      --
      type Emission_mode is (simulate, effective);
      --
      procedure Emit_data_compression_structures(mode: Emission_mode) is
        procedure Emit_data_compression_atom(x: Natural; extra: U32:= 0; bits: Natural:= 0) is
        --  x is a bit length (value in 0..15), or a RLE instruction
        begin
          case mode is
            when simulate =>
              truc_freq(x):= truc_freq(x) + 1;  --  +1 for x's histogram bar
            when effective =>
              Put_code(truc(x));
              if bits > 0 then
                Put_code(extra, bits);
              end if;
          end case;
        end Emit_data_compression_atom;
        --
        cs_bl: array(1 .. dhd.lit_len'Length + dhd.dis'Length) of Natural;
        last_cs_bl: Natural;
        idx: Natural:= 0;
        rep: Positive;  --  Number of times current atom is repeated, >= 1
      begin
        if mode = simulate then
          for a in reverse Alphabet_lit_len loop
            if dhd.lit_len(a).length > 0 then
              max_used_lln_code:= a;
              exit;
            end if;
          end loop;
          for a in reverse Alphabet_dis loop
            if dhd.dis(a).length > 0 then
              max_used_dis_code:= a;
              exit;
            end if;
          end loop;
        end if;
        --  Copy bit lengths for both trees into one array
        for a in 0..max_used_lln_code loop
          idx:= idx + 1;
          cs_bl(idx):= dhd.lit_len(a).length;
        end loop;
        for a in 0..max_used_dis_code loop
          idx:= idx + 1;
          cs_bl(idx):= dhd.dis(a).length;
        end loop;
        last_cs_bl:= idx;
        --  Emit the bit lengths, with some RLE encoding (Appnote: 5.5.3; RFC 1951: 3.2.7)
        idx:= 1;
        loop
          rep:= 1;  --  Current atom, cs_bl(idx), is repeated 1x so far - obvious, isn't it ?
          for j in idx + 1 .. last_cs_bl loop
            exit when cs_bl(j) /= cs_bl(idx);
            rep:= rep + 1;
          end loop;
          --  Now rep is the number of repetitions of current atom, including itself.
          if idx > 1 and then cs_bl(idx) = cs_bl(idx-1) and then rep >= 3 then
            rep:= Integer'Min(rep, 6);
            Emit_data_compression_atom(16, U32(rep-3), 2);    -- 16: "Repeat previous 3 to 6 times"
            idx:= idx + rep;
          elsif cs_bl(idx) = 0 and then rep >= 3 then
            --  The 0 bit length may occur on long ranges of an alphabet (unused symbols)
            if rep <= 10 then
              Emit_data_compression_atom(17, U32(rep-3), 3);  -- 17: "Repeat zero 3 to 10 times"
            else
              rep:= Integer'Min(rep, 138);
              Emit_data_compression_atom(18, U32(rep-11), 7); -- 18: "Repeat zero 11 to 138 times"
            end if;
            idx:= idx + rep;
          else
            Emit_data_compression_atom(cs_bl(idx));
            idx:= idx + 1;
          end if;
          exit when idx > last_cs_bl;
        end loop;
      end Emit_data_compression_structures;
      --
      bit_order_for_dynamic_block : constant array (Alphabet) of Natural :=  --  Permutation
         ( 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 );
      --  For example, bit lengths 1 and 15 don't occur in the two Huffman trees for data, then
      --  1 and 15 have a length 0 in the local Alphabet -> omit sending the last two lengths.
      procedure LLHCL is new
        Length_limited_Huffman_code_lengths(Alphabet, Natural, Alpha_Array, Alpha_Array, 7);
      a_non_zero: Alphabet;
    begin
      truc_freq:= (others => 0);
      Emit_data_compression_structures(simulate);
      --  We have now statistics of all bit lengths occurrences of both Huffman
      --  trees used for compressing the data.
      --  We turn these counts into bit lengths for the local tree
      --  that helps us to store the compression structure in a more compact form.
      LLHCL(truc_freq, truc_bl);  --  Call the magic algorithm for setting up Huffman lengths
      for a in Alphabet loop
        truc(a).length:= truc_bl(a);
      end loop;
      Prepare_codes(truc);         --  Build the Huffman codes described by the bit lengths
      a_non_zero:= 3;
      --  At least lengths for codes 16, 17, 18, 0 will always be sent if the other lengths are 0
      for a in Alphabet loop
        if a > a_non_zero and then truc(bit_order_for_dynamic_block(a)).length > 0 then
          a_non_zero:= a;
        end if;
      end loop;
      --  Output of the compression structure
      Put_code(U32(max_used_lln_code - 256), 5);  --  max_used_lln_code is always >= 256 = EOB code
      Put_code(U32(max_used_dis_code), 5);
      Put_code(U32(a_non_zero - 3), 4);
      --  Save the local alphabet's Huffman lengths. It's the compression
      --  structure for compressing the data compression structure. Easy isn't it ?
      for a in 0..a_non_zero loop
        Put_code(U32(truc(bit_order_for_dynamic_block(a)).length), 3);
      end loop;
      --  Emit the Huffman lengths for encoding the data, in the local Huffman-encoded fashion.
      Emit_data_compression_structures(effective);
    end Put_compression_structure;

    --  Current tree descriptors
    descr: Deflate_Huff_descriptors:= Deflate_fixed_descriptors;

    --  Write a normal, "clear-text" (post LZ, pre Huffman), 8-bit character (literal)
    procedure Put_literal_byte( b: Byte ) is
    begin
      Put_code( descr.lit_len(Integer(b)) );
      -- put("{"&character'val(b)&"}");
      Text_Buf(R):= b;
      R:= R+1;
    end Put_literal_byte;

    --  Possible ranges for distance and length encoding in the Zip-Deflate format:
    subtype Length_range is Integer range 3 .. 258;
    subtype Distance_range is Integer range 1 .. 32768;

    --  !! Check performance: perhaps use arrays instead of case statements 

    procedure Put_DL_code( distance, length: Integer ) is
    begin
      -- Already checked: distance in Distance_range and length in Length_range
      --
      -- put('('&distance'img & ',' & length'img&')');

      --                             Length Codes
      --                             ------------
      --      Extra             Extra              Extra              Extra
      -- Code Bits Length  Code Bits Lengths  Code Bits Lengths  Code Bits Length(s)
      -- ---- ---- ------  ---- ---- -------  ---- ---- -------  ---- ---- ---------
      --  257   0     3     265   1   11,12    273   3   35-42    281   5  131-162
      --  258   0     4     266   1   13,14    274   3   43-50    282   5  163-194
      --  259   0     5     267   1   15,16    275   3   51-58    283   5  195-226
      --  260   0     6     268   1   17,18    276   3   59-66    284   5  227-257
      --  261   0     7     269   2   19-22    277   4   67-82    285   0    258
      --  262   0     8     270   2   23-26    278   4   83-98
      --  263   0     9     271   2   27-30    279   4   99-114
      --  264   0    10     272   2   31-34    280   4  115-130
      --
      --  Example: the code # 266 means the LZ length (# of message bytes to be copied)
      --           shall be 13 or 14, depending on the extra bit value.
      --
      case Length_range(length) is
        when 3..10 => -- Codes 257..264, with no extra bit
          Put_code( descr.lit_len( 257 + length-3 ) );
        when 11..18 => -- Codes 265..268, with 1 extra bit
          Put_code( descr.lit_len( 265 + (length-11) / 2 ) );
          Put_code( U32((length-11) mod 2), 1 );
        when 19..34 => -- Codes 269..272, with 2 extra bits
          Put_code( descr.lit_len( 269 + (length-19) / 4 ) );
          Put_code( U32((length-19) mod 4), 2 );
        when 35..66 => -- Codes 273..276, with 3 extra bits
          Put_code( descr.lit_len( 273 + (length-35) / 8 ) );
          Put_code( U32((length-35) mod 8), 3 );
        when 67..130 => -- Codes 277..280, with 4 extra bits
          Put_code( descr.lit_len( 277 + (length-67) / 16 ) );
          Put_code( U32((length-67) mod 16), 4 );
        when 131..257 => -- Codes 281..284, with 5 extra bits
          Put_code( descr.lit_len( 281 + (length-131) / 32 ) );
          Put_code( U32((length-131) mod 32), 5 );
        when 258 => -- Code 285, with no extra bit
          Put_code( descr.lit_len( 285 ) );
      end case;
      --                            Distance Codes
      --                            --------------
      --      Extra           Extra             Extra               Extra
      -- Code Bits Dist  Code Bits  Dist   Code Bits Distance  Code Bits Distance
      -- ---- ---- ----  ---- ---- ------  ---- ---- --------  ---- ---- --------
      --   0   0    1      8   3   17-24    16    7  257-384    24   11  4097-6144
      --   1   0    2      9   3   25-32    17    7  385-512    25   11  6145-8192
      --   2   0    3     10   4   33-48    18    8  513-768    26   12  8193-12288
      --   3   0    4     11   4   49-64    19    8  769-1024   27   12 12289-16384
      --   4   1   5,6    12   5   65-96    20    9 1025-1536   28   13 16385-24576
      --   5   1   7,8    13   5   97-128   21    9 1537-2048   29   13 24577-32768
      --   6   2   9-12   14   6  129-192   22   10 2049-3072
      --   7   2  13-16   15   6  193-256   23   10 3073-4096
      --
      --
      --  Example: the code # 10 means the LZ distance (# positions back in the circular
      --           message buffer for starting the copy) shall be 33, plus the value given
      --           by the 4 extra bits (between 0 and 15).
      case Distance_range(distance) is
        when 1..4 => -- Codes 0..3, with no extra bit
          Put_code( descr.dis(distance-1) );
        when 5..8 => -- Codes 4..5, with 1 extra bit
          Put_code( descr.dis( 4 + (distance-5) / 2 ) );
          Put_code( U32((distance-5) mod 2), 1 );
        when 9..16 => -- Codes 6..7, with 2 extra bits
          Put_code( descr.dis( 6 + (distance-9) / 4 ) );
          Put_code( U32((distance-9) mod 4), 2 );
        when 17..32 => -- Codes 8..9, with 3 extra bits
          Put_code( descr.dis( 8 + (distance-17) / 8 ) );
          Put_code( U32((distance-17) mod 8), 3 );
        when 33..64 => -- Codes 10..11, with 4 extra bits
          Put_code( descr.dis( 10 + (distance-33) / 16 ) );
          Put_code( U32((distance-33) mod 16), 4 );
        when 65..128 => -- Codes 12..13, with 5 extra bits
          Put_code( descr.dis( 12 + (distance-65) / 32 ) );
          Put_code( U32((distance-65) mod 32), 5 );
        when 129..256 => -- Codes 14..15, with 6 extra bits
          Put_code( descr.dis( 14 + (distance-129) / 64 ) );
          Put_code( U32((distance-129) mod 64), 6 );
        when 257..512 => -- Codes 16..17, with 7 extra bits
          Put_code( descr.dis( 16 + (distance-257) / 128 ) );
          Put_code( U32((distance-257) mod 128), 7 );
        when 513..1024 => -- Codes 18..19, with 8 extra bits
          Put_code( descr.dis( 18 + (distance-513) / 256 ) );
          Put_code( U32((distance-513) mod 256), 8 );
        when 1025..2048 => -- Codes 20..21, with 9 extra bits
          Put_code( descr.dis( 20 + (distance-1025) / 512 ) );
          Put_code( U32((distance-1025) mod 512), 9 );
        when 2049..4096 => -- Codes 22..23, with 10 extra bits
          Put_code( descr.dis( 22 + (distance-2049) / 1024 ) );
          Put_code( U32((distance-2049) mod 1024), 10 );
        when 4097..8192 => -- Codes 24..25, with 11 extra bits
          Put_code( descr.dis( 24 + (distance-4097) / 2048 ) );
          Put_code( U32((distance-4097) mod 2048), 11 );
        when 8193..16384 => -- Codes 26..27, with 12 extra bits
          Put_code( descr.dis( 26 + (distance-8193) / 4096 ) );
          Put_code( U32((distance-8193) mod 4096), 12 );
        when 16385..32768 => -- Codes 28..29, with 13 extra bits
          Put_code( descr.dis( 28 + (distance-16385) / 8192 ) );
          Put_code( U32((distance-16385) mod 8192), 13 );
      end case;
    end Put_DL_code;

    --  !! Check performance: perhaps use arrays instead of case statements 

    function Deflate_code_for_LZ_length(length: Natural) return Natural is
    begin
      case Length_range(length) is
        when 3..10 => -- Codes 257..264, with no extra bit
          return 257 + length-3;
        when 11..18 => -- Codes 265..268, with 1 extra bit
          return 265 + (length-11) / 2;
        when 19..34 => -- Codes 269..272, with 2 extra bits
          return 269 + (length-19) / 4;
        when 35..66 => -- Codes 273..276, with 3 extra bits
          return 273 + (length-35) / 8;
        when 67..130 => -- Codes 277..280, with 4 extra bits
          return 277 + (length-67) / 16;
        when 131..257 => -- Codes 281..284, with 5 extra bits
          return 281 + (length-131) / 32;
        when 258 => -- Code 285, with no extra bit
          return 285;
      end case;
    end Deflate_code_for_LZ_length;

    --  !! Check performance: perhaps use arrays instead of case statements 

    function Deflate_code_for_LZ_distance(distance: Natural) return Natural is
    begin
      case Distance_range(distance) is
        when 1..4 => -- Codes 0..3, with no extra bit
          return distance-1 ;
        when 5..8 => -- Codes 4..5, with 1 extra bit
          return  4 + (distance-5) / 2  ;
        when 9..16 => -- Codes 6..7, with 2 extra bits
          return  6 + (distance-9) / 4  ;
        when 17..32 => -- Codes 8..9, with 3 extra bits
          return  8 + (distance-17) / 8  ;
        when 33..64 => -- Codes 10..11, with 4 extra bits
          return  10 + (distance-33) / 16  ;
        when 65..128 => -- Codes 12..13, with 5 extra bits
          return  12 + (distance-65) / 32  ;
        when 129..256 => -- Codes 14..15, with 6 extra bits
          return  14 + (distance-129) / 64  ;
        when 257..512 => -- Codes 16..17, with 7 extra bits
          return  16 + (distance-257) / 128  ;
        when 513..1024 => -- Codes 18..19, with 8 extra bits
          return  18 + (distance-513) / 256  ;
        when 1025..2048 => -- Codes 20..21, with 9 extra bits
          return  20 + (distance-1025) / 512  ;
        when 2049..4096 => -- Codes 22..23, with 10 extra bits
          return  22 + (distance-2049) / 1024  ;
        when 4097..8192 => -- Codes 24..25, with 11 extra bits
          return  24 + (distance-4097) / 2048  ;
        when 8193..16384 => -- Codes 26..27, with 12 extra bits
          return  26 + (distance-8193) / 4096  ;
        when 16385..32768 => -- Codes 28..29, with 13 extra bits
          return  28 + (distance-16385) / 8192  ;
      end case;
    end Deflate_code_for_LZ_distance;

    -----------------
    --  LZ Buffer  --
    -----------------

    --  We buffer the LZ codes (plain, or distance/length) in order to
    --  analyse them and try to do smart things.

    type LZ_atom_kind is (plain_byte, distance_length);
    type LZ_atom is record
      kind          : LZ_atom_kind;
      plain         : Byte;
      lz_distance   : Natural;
      lz_length     : Natural;
      lz_copy_start : Text_buffer_index;  --  In case we need to grab un-lz-compressed data
    end record;

    LZ_buffer_size: constant:= 2**14;
    type LZ_buffer_index_type is mod LZ_buffer_size;
    type LZ_buffer_type is array (LZ_buffer_index_type range <>) of LZ_atom;
    lz_buffer: LZ_buffer_type(LZ_buffer_index_type);

    procedure Get_statistics(
      lz_buffer     :     LZ_buffer_type;
      stats_lit_len : out Stats_lit_len_type;
      stats_dis     : out Stats_dis_type
    )
    is
      lit_len: Alphabet_lit_len;
      dis: Alphabet_dis;
    begin
      stats_lit_len:= (End_Of_Block => 1, others => 0);
      --  ^ End_Of_Block has to happen once, but never appears in the statistics...
      stats_dis:= (others => 0);
      --
      --  Compute statistics for both Literal-length, and Distance alphabets, from the LZ buffer
      --
      for i in lz_buffer'Range loop
        case lz_buffer(i).kind is
          when plain_byte =>
            lit_len:= Alphabet_lit_len(lz_buffer(i).plain);
            stats_lit_len(lit_len):= stats_lit_len(lit_len) + 1;          --  +1 for this literal
          when distance_length =>
            lit_len:= Deflate_code_for_LZ_length(lz_buffer(i).lz_length);
            stats_lit_len(lit_len):= stats_lit_len(lit_len) + 1;          --  +1 for this length
            dis:= Deflate_code_for_LZ_distance(lz_buffer(i).lz_distance);
            stats_dis(dis):= stats_dis(dis) + 1;                          --  +1 for this distance
        end case;
      end loop;
    end Get_statistics;

    --  Send a LZ buffer with current Huffman codes
    procedure Put_LZ_buffer(lz_buffer: LZ_buffer_type) is
    begin
      for i in lz_buffer'Range loop
        case lz_buffer(i).kind is
          when plain_byte =>
            Put_literal_byte(lz_buffer(i).plain);
          when distance_length =>
            Put_DL_code(lz_buffer(i).lz_distance, lz_buffer(i).lz_length);
        end case;
      end loop;
    end Put_LZ_buffer;

    --  Send a LZ buffer completely decoded
    procedure Expand_LZ_buffer(lz_buffer: LZ_buffer_type) is
    begin
      for i in lz_buffer'Range loop
        case lz_buffer(i).kind is
          when plain_byte =>
            Put_byte(lz_buffer(i).plain);
          when distance_length =>
            for K in 0..Text_buffer_index(lz_buffer(i).lz_length-1) loop
              Put_byte( Text_Buf(lz_buffer(i).lz_copy_start + K) );
            end loop;
        end case;
      end loop;
    end Expand_LZ_buffer;

    block_to_finish: Boolean:= False;
    last_block_marked: Boolean:= False;

    procedure Mark_new_block(last_block_for_stream: Boolean) is
    begin
      if block_to_finish then
        Put_code(descr.lit_len(End_Of_Block));  --  Finish previous block
      end if;
      block_to_finish:= True;
      Put_code(code => Boolean'Pos(last_block_for_stream), code_size => 1);
      last_block_marked:= last_block_for_stream;
    end Mark_new_block;

    lz_buffer_index: LZ_buffer_index_type:= 0;
    lz_buffer_full: Boolean:= False;
    pragma Unreferenced (lz_buffer_full);
    --  When True: all LZ_buffer_size data before lz_buffer_index (modulo!) are real data

    type Block_type is (stored, fixed, dynamic, reserved);  --  Appnote, 5.5.2
    last_block_type: Block_type:= reserved;  --  If dynamic, we may recycle previous block
    
    --  !! Suboptimal so far. Currently a big fat block is sent one after the other.
    --     More to come in this place :-) ...
    procedure Flush_from_0(last_flush: Boolean) is
      stats_lit_len: Stats_lit_len_type;
      stats_dis: Stats_dis_type;
      new_descr: Deflate_Huff_descriptors;
    begin
      Get_statistics(lz_buffer(0..lz_buffer_index-1), stats_lit_len, stats_dis);
      new_descr:= Build_descriptors(stats_lit_len, stats_dis);
      if Similar(random_data_descriptors, new_descr, L1, 25, "Compare to random") then
        if trace then
          Put_Line(log, "### Use stored");
        end if;
        -- !! here just trace occurrences
      end if;
--      last_block_type:= stored;
--      Mark_new_block(last_block_for_stream => last_flush);
--      Flush_bit_output;
--      Expand_LZ_buffer(lz_buffer(0..lz_buffer_index-1));  --  TBD, cf UnZip.Decompress:1460
--    else
      if last_block_type = dynamic and then 
         Similar(descr, new_descr, L1, 30, "Compare to previous") and then
         Recyclable(descr, new_descr)
      then
        if trace then
          Put_Line(log, "### Recycle dynamic");
        end if;
        Put_LZ_buffer(lz_buffer(0..lz_buffer_index-1));
      elsif Similar(Deflate_fixed_descriptors, new_descr, L1, 30, "Compare to fixed") then
        if trace then
          Put_Line(log, "### Use fixed");
        end if;
        last_block_type:= fixed;
        Mark_new_block(last_block_for_stream => last_flush);
        -- ^ Eventually, last_block_for_stream will be last block of last flush in a later version
        descr:= Deflate_fixed_descriptors;
        Put_code(code => 1, code_size => 2);  --  Signals a "fixed" block
        Put_LZ_buffer(lz_buffer(0..lz_buffer_index-1));
      else
        last_block_type:= dynamic;
        Mark_new_block(last_block_for_stream => last_flush);
        -- ^ Eventually, last_block_for_stream will be last block of last flush in a later version
        descr:= new_descr;
        Put_code(code => 2, code_size => 2);  --  Signals a "dynamic" block
        Put_compression_structure(descr);
        Put_LZ_buffer(lz_buffer(0..lz_buffer_index-1));
      end if;
      lz_buffer_full:= True;
    end Flush_from_0;

    procedure Push(a: LZ_atom) is
    begin
      lz_buffer(lz_buffer_index):= a;
      lz_buffer_index:= lz_buffer_index + 1;  --  becomes 0 when reaching LZ_buffer_size (modular)
      if lz_buffer_index = 0 then
        Flush_from_0(last_flush => False);
      end if;
    end Push;

    procedure Put_or_delay_literal_byte( b: Byte ) is
    pragma Inline(Put_or_delay_literal_byte);
    begin
      case method is
        when Deflate_Fixed =>
          Put_literal_byte(b);  --  Buffering is not needed in this mode
        when Deflate_1 =>
          Push((plain_byte, b, 0, 0, 0));
      end case;
    end Put_or_delay_literal_byte;

    procedure Put_or_delay_DL_code( distance, length: Integer; copy_start: Text_buffer_index ) is
    pragma Inline(Put_or_delay_DL_code);
    begin
      case method is
        when Deflate_Fixed =>
          Put_DL_code(distance, length);  --  Buffering is not needed in this mode
        when Deflate_1 =>
          Push((distance_length, 0, distance, length, copy_start));
      end case;
    end Put_or_delay_DL_code;

    procedure LZ77_emits_DL_code( distance, length: Integer ) is
      --  NB: no worry, all arithmetics in Text_buffer_index are modulo String_buffer_size.
      copy_start: constant Text_buffer_index:= R - Text_buffer_index(distance);
    begin
      if distance in Distance_range and length in Length_range then
        Put_or_delay_DL_code(distance, length, copy_start);
        -- Expand in the circular text buffer to have it up to date
        for K in 0..Text_buffer_index(length-1) loop
          Text_Buf(R):= Text_Buf(copy_start + K);
          R:= R + 1;
        end loop;
      else
        -- Cannot encode this distance-length pair, then we have to expand to output :-(
        -- if phase= compress then Put("Aie! (" & distance'img & length'img & ")"); end if;
        for K in 0..Text_buffer_index(length-1) loop
          Put_or_delay_literal_byte( Text_Buf(Copy_start+K) );
        end loop;
      end if;
    end LZ77_emits_DL_code;

    procedure My_LZ77 is
      new LZ77(
        String_buffer_size, Look_Ahead, Threshold,
        Read_byte, More_bytes,
        Put_or_delay_literal_byte, LZ77_emits_DL_code
      );

  begin  --  Encode
    Read_Block;
    R:= Text_buffer_index(String_buffer_size - Look_Ahead);
    Bytes_in := 0;
    if input_size_known then
      X_Percent := Integer(input_size / 40);
    else
      X_Percent := 0;
    end if;
    case method is
      when Deflate_Fixed =>  --  "Fixed" (predefined) compression structure
        --  We have only one compressed data block, then it is already the last one.
        Put_code(code => 1, code_size => 1);  --  Signals last block
        Put_code(code => 1, code_size => 2);  --  Signals a "fixed" block
      when Deflate_1 =>
        null;  --  No start data sent, all is delayed
    end case;
    -----------------------------------------------
    --  The whole compression is happening here: --
    -----------------------------------------------
    My_LZ77;
    --  Done. Send the code signalling the end of compressed data block:
    case method is
      when Deflate_Fixed =>
        Put_code(descr.lit_len(End_Of_Block));
      when Deflate_1 =>
        if lz_buffer_index = 0 then  --  Already flushed at latest Push, or empty data
          if block_to_finish and then last_block_type in fixed .. dynamic then
            Put_code(descr.lit_len(End_Of_Block));
          end if;
        else
          Flush_from_0(last_flush => True);
          if last_block_type in fixed .. dynamic then
            Put_code(descr.lit_len(End_Of_Block));
          end if;
        end if;
        if not last_block_marked then
          --  Add a fake fixed block, just to have a final block...
          Put_code(code => 1, code_size => 1);  --  Signals last block
          Put_code(code => 1, code_size => 2);  --  Signals a "fixed" block
          descr:= Deflate_fixed_descriptors;
          Put_code(descr.lit_len(End_Of_Block));
        end if;
    end case;
  end Encode;

begin
  if trace then
    begin
      Open(log, Append_File, log_name);
    exception
      when Name_Error =>
        Create(log, Out_File, log_Name);
    end;
    Put(log, "New stream" & sep & sep & sep & sep & sep & sep & sep & sep);
    if input_size_known then
      Put(log, sep & File_size_type'Image(input_size) &
               sep & sep & sep & sep & sep & sep & "bytes input");
    end if;
    New_Line(log);
  end if;
  --  Initialize output byte buffer
  OutBufIdx := 1;
  output_size:= 0;
  --  Initialize output bit buffer
  Save_byte := 0;
  Bits_used := 0;
  Encode;
  Flush_bit_output;
  if trace then
    Close(log);
  end if;
  compression_ok:= True;
exception
  when Compression_unefficient =>
    if trace then
      Close(log);
    end if;
    compression_ok:= False;
end Zip.Compress.Deflate;
