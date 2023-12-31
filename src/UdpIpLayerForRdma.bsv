import FIFOF :: *;

import Ports :: *;
import Utils :: *;
import UdpIpLayer :: *;
import EthernetTypes :: *;
import StreamHandler :: *;

import SemiFifo :: *;
import CrcDefines :: *;
import AxiStreamTypes :: *;

function UdpIpHeader genUdpIpHeaderForRoCE(UdpIpMetaData metaData, UdpConfig udpConfig, IpID ipId);
    let udpIpHeader = genUdpIpHeader(metaData, udpConfig, ipId);

    let crc32ByteWidth = valueOf(CRC32_BYTE_WIDTH);
    let udpLen = udpIpHeader.udpHeader.length;
    udpIpHeader.udpHeader.length = udpLen + fromInteger(crc32ByteWidth);
    let ipLen = udpIpHeader.ipHeader.ipTL;
    udpIpHeader.ipHeader.ipTL = ipLen + fromInteger(crc32ByteWidth);

    return udpIpHeader;
endfunction

function UdpIpHeader genUdpIpHeaderForICrc(UdpIpMetaData metaData, UdpConfig udpConfig, IpID ipId);
    let udpIpHeader = genUdpIpHeaderForRoCE(metaData, udpConfig, ipId);

    udpIpHeader.ipHeader.ipDscp = setAllBits;
    udpIpHeader.ipHeader.ipEcn = setAllBits;
    udpIpHeader.ipHeader.ipTTL = setAllBits;
    udpIpHeader.ipHeader.ipChecksum = setAllBits;

    udpIpHeader.udpHeader.checksum = setAllBits;

    return udpIpHeader;
endfunction


module mkUdpIpStreamForICrcGen#(
    UdpIpMetaDataPipeOut udpIpMetaDataIn,
    DataStreamPipeOut dataStreamIn,
    UdpConfig udpConfig
)(DataStreamPipeOut);
    Reg#(Bool) isFirstReg <- mkReg(True);
    Reg#(IpID) ipIdCounter <- mkReg(0);
    FIFOF#(DataStream) dataStreamBuf <- mkFIFOF;
    FIFOF#(UdpIpHeader) udpIpHeaderBuf <- mkFIFOF;
    FIFOF#(Bit#(DUMMY_BITS_WIDTH)) dummyBitsBuf <- mkFIFOF;

    rule genDataStream;
        let dataStream = dataStreamIn.first;
        dataStreamIn.deq;
        if (isFirstReg) begin
            let swappedData = swapEndian(dataStream.data);
            BTH bth = unpack(truncateLSB(swappedData));
            bth.fecn = setAllBits;
            bth.becn = setAllBits;
            bth.resv6 = setAllBits;
            Data maskedData = {pack(bth), truncate(swappedData)};
            dataStream.data = swapEndian(maskedData);
        end
        dataStreamBuf.enq(dataStream);
        isFirstReg <= dataStream.isLast;
    endrule

    rule genUdpIpHeader;
        let metaData = udpIpMetaDataIn.first;
        udpIpMetaDataIn.deq;
        UdpIpHeader udpIpHeader = genUdpIpHeaderForICrc(metaData, udpConfig, 1);
        udpIpHeaderBuf.enq(udpIpHeader);
        ipIdCounter <= ipIdCounter + 1;
        $display("IpUdpGen: genHeader of %d frame", ipIdCounter);
    endrule

    rule genDummyBits;
        dummyBitsBuf.enq(setAllBits);
    endrule

    DataStreamPipeOut udpIpStream <- mkAppendDataStreamHead(
        HOLD,
        SWAP,
        convertFifoToPipeOut(dataStreamBuf),
        convertFifoToPipeOut(udpIpHeaderBuf)
    );
    DataStreamPipeOut dummyBitsAndUdpIpStream <- mkAppendDataStreamHead(
        HOLD,
        SWAP,
        udpIpStream,
        convertFifoToPipeOut(dummyBitsBuf)
    );
    return dummyBitsAndUdpIpStream;
endmodule


module mkUdpIpStreamForRdma#(
    UdpIpMetaDataPipeOut udpIpMetaDataIn,
    DataStreamPipeOut dataStreamIn,
    UdpConfig udpConfig
)(DataStreamPipeOut);

    FIFOF#(DataStream) dataStreamBuf <- mkFIFOF;
    FIFOF#(DataStream) dataStreamCrcBuf <- mkFIFOF;
    FIFOF#(UdpIpMetaData) udpIpMetaDataBuf <- mkFIFOF;
    FIFOF#(UdpIpMetaData) udpIpMetaDataCrcBuf <- mkFIFOF;
    FIFOF#(UdpLength) preComputeLengthBuf <- mkFIFOF;

    rule forkUdpIpMetaDataIn;
        let udpIpMetaData = udpIpMetaDataIn.first;
        udpIpMetaDataIn.deq;
        udpIpMetaDataBuf.enq(udpIpMetaData);
        udpIpMetaDataCrcBuf.enq(udpIpMetaData);
        let dataStreamLen = udpIpMetaData.dataLen +
                            fromInteger(valueOf(IP_HDR_BYTE_WIDTH)) +
                            fromInteger(valueOf(UDP_HDR_BYTE_WIDTH));
        preComputeLengthBuf.enq(dataStreamLen);
    endrule

    rule forkDataStreamIn;
        let dataStream = dataStreamIn.first;
        dataStreamIn.deq;
        dataStreamBuf.enq(dataStream);
        dataStreamCrcBuf.enq(dataStream);
    endrule

    DataStreamPipeOut udpIpStream <- mkUdpIpStream(
        udpConfig,
        convertFifoToPipeOut(dataStreamBuf),
        convertFifoToPipeOut(udpIpMetaDataBuf),
        genUdpIpHeaderForRoCE
    );

    DataStreamPipeOut udpIpStreamForICrc <- mkUdpIpStreamForICrcGen(
        convertFifoToPipeOut(udpIpMetaDataCrcBuf),
        convertFifoToPipeOut(dataStreamCrcBuf),
        udpConfig
    );

    let crc32Stream <- mkCrc32AxiStream256PipeOut(
        CRC_MODE_SEND,
        convertDataStreamToAxiStream256(udpIpStreamForICrc)
    );

    DataStreamPipeOut udpIpStreamWithICrc <- mkAppendDataStreamTail(
        HOLD,
        HOLD,
        udpIpStream,
        crc32Stream,
        convertFifoToPipeOut(preComputeLengthBuf)
    );

    return udpIpStreamWithICrc;
endmodule


function UdpIpMetaData extractUdpIpMetaDataForRoCE(UdpIpHeader hdr);
    let meta = extractUdpIpMetaData(hdr);
    meta.dataLen = meta.dataLen - fromInteger(valueOf(CRC32_BYTE_WIDTH));
    return meta;
endfunction

module mkUdpIpStreamForICrcChk#(
    DataStreamPipeOut udpIpStreamIn
)(DataStreamPipeOut);
    Reg#(Bool) isFirst <- mkReg(True);
    FIFOF#(AxiStream512) interAxiStreamBuf <- mkFIFOF;
    FIFOF#(Bit#(DUMMY_BITS_WIDTH)) dummyBitsBuf <- mkFIFOF;
    let axiStream512PipeOut <- mkDataStreamToAxiStream512(udpIpStreamIn);
    let udpIpStreamPipeOut <- mkAxiStream512ToDataStream(
        convertFifoToPipeOut(interAxiStreamBuf)
    );
    let dummyBitsAndUdpIpStream <- mkAppendDataStreamHead(
        HOLD,
        SWAP,
        udpIpStreamPipeOut,
        convertFifoToPipeOut(dummyBitsBuf)
    );

    rule genDummyBits;
        dummyBitsBuf.enq(setAllBits);
    endrule

    rule doTransform;
        let axiStream512 = axiStream512PipeOut.first;
        axiStream512PipeOut.deq;
        if (isFirst) begin
            let tData = swapEndian(axiStream512.tData);
            BTHUdpIpHeader bthUdpIpHdr = unpack(truncateLSB(tData));
            bthUdpIpHdr.bth.fecn = setAllBits;
            bthUdpIpHdr.bth.becn = setAllBits;
            bthUdpIpHdr.bth.resv6 = setAllBits;
            bthUdpIpHdr.udpHeader.checksum = setAllBits;
            bthUdpIpHdr.ipHeader.ipDscp = setAllBits;
            bthUdpIpHdr.ipHeader.ipEcn = setAllBits;
            bthUdpIpHdr.ipHeader.ipTTL = setAllBits;
            bthUdpIpHdr.ipHeader.ipChecksum = setAllBits;
            tData = {pack(bthUdpIpHdr), truncate(tData)};
            axiStream512.tData = swapEndian(tData);
        end
        isFirst <= axiStream512.tLast;
        interAxiStreamBuf.enq(axiStream512);
    endrule

    return dummyBitsAndUdpIpStream;
endmodule


module mkRemoveICrcFromDataStream#(
    PipeOut#(Bit#(streamLenWidth)) streamLenIn,
    DataStreamPipeOut dataStreamIn
)(DataStreamPipeOut) provisos(
    NumAlias#(TLog#(DATA_BUS_BYTE_WIDTH), frameLenWidth),
    NumAlias#(TLog#(TAdd#(CRC32_BYTE_WIDTH, 1)), shiftAmtWidth),
    Add#(frameLenWidth, frameNumWidth, streamLenWidth)
);
    Integer crc32ByteWidth = valueOf(CRC32_BYTE_WIDTH);
    // +Reg +Cnt
    Reg#(Bool) isGetStreamLenReg <- mkReg(False);
    Reg#(Bool) isICrcInterFrameReg <- mkRegU;
    Reg#(Bit#(shiftAmtWidth)) frameShiftAmtReg <- mkRegU;
    Reg#(DataStream) foreDataStreamReg <- mkRegU;

    FIFOF#(DataStream) dataStreamOutBuf <- mkFIFOF;

    rule getStreamLen if (!isGetStreamLenReg);
        let streamLen = streamLenIn.first;
        streamLenIn.deq;
        Bit#(frameLenWidth) lastFrameLen = truncate(streamLen);
        
        if (lastFrameLen > fromInteger(crc32ByteWidth) || lastFrameLen == 0) begin
            isICrcInterFrameReg <= False;
            frameShiftAmtReg <= fromInteger(crc32ByteWidth);
            //$display("Remove ICRC shiftAmt=%d", frameShiftAmtReg);
        end
        else begin
            isICrcInterFrameReg <= True;
            frameShiftAmtReg <= truncate(fromInteger(crc32ByteWidth) - lastFrameLen);
        end
        isGetStreamLenReg <= True;
    endrule

    rule passDataStream if (isGetStreamLenReg);
        let dataStream = dataStreamIn.first;
        dataStreamIn.deq;
        
        if (!isICrcInterFrameReg) begin
            if (dataStream.isLast) begin
                let byteEn = dataStream.byteEn >> frameShiftAmtReg;
                dataStream.byteEn = byteEn;
                dataStream.data = bitMask(dataStream.data, byteEn);
            end
            dataStreamOutBuf.enq(dataStream);
        end
        else begin
            foreDataStreamReg <= dataStream;
            let foreDataStream = foreDataStreamReg;
            if (dataStream.isLast) begin
                let byteEn = foreDataStream.byteEn >> frameShiftAmtReg;
                foreDataStream.byteEn = byteEn;
                foreDataStream.data = bitMask(foreDataStream.data, byteEn);
                foreDataStream.isLast = True;
            end
            if (!dataStream.isFirst) begin
                dataStreamOutBuf.enq(foreDataStream);
            end
        end
        if (dataStream.isLast) begin
            isGetStreamLenReg <= False;
        end
    endrule

    return convertFifoToPipeOut(dataStreamOutBuf);
endmodule

typedef 4096 RDMA_PACKET_MAX_SIZE;
typedef 3 RDMA_META_BUF_SIZE;
typedef TDiv#(RDMA_PACKET_MAX_SIZE, DATA_BUS_BYTE_WIDTH) RDMA_PACKET_MAX_FRAME;
typedef TAdd#(RDMA_PACKET_MAX_FRAME, 16) RDMA_PAYLOAD_BUF_SIZE;

typedef enum {
    ICRC_IDLE,
    ICRC_META,
    ICRC_PAYLOAD
} ICrcCheckState deriving(Bits, Eq, FShow);

module mkUdpIpMetaDataAndDataStreamForRdma#(
    DataStreamPipeOut udpIpStreamIn,
    UdpConfig udpConfig
)(UdpIpMetaDataAndDataStream);

    FIFOF#(DataStream) udpIpStreamBuf <- mkFIFOF;
    FIFOF#(DataStream) udpIpStreamForICrcBuf <- mkFIFOF;

    rule forkUdpIpStream;
        let udpIpStream = udpIpStreamIn.first;
        udpIpStreamIn.deq;
        udpIpStreamBuf.enq(udpIpStream);
        udpIpStreamForICrcBuf.enq(udpIpStream);
    endrule

    DataStreamPipeOut udpIpStreamForICrc <- mkUdpIpStreamForICrcChk(
        convertFifoToPipeOut(udpIpStreamForICrcBuf)
    );

    let crc32Stream <- mkCrc32AxiStream256PipeOut(
        CRC_MODE_RECV,
        convertDataStreamToAxiStream256(udpIpStreamForICrc)
    );

    UdpIpMetaDataAndDataStream udpIpMetaAndDataStream <- mkUdpIpMetaDataAndDataStream(
        udpConfig,
        convertFifoToPipeOut(udpIpStreamBuf),
        extractUdpIpMetaDataForRoCE
    );

    FIFOF#(UdpLength) dataStreamLengthBuf <- mkFIFOF;
    FIFOF#(UdpIpMetaData) udpIpMetaDataBuf <- mkFIFOF;
    rule forkUdpIpMetaData;
        Integer iCrcByteWidth = valueOf(CRC32_BYTE_WIDTH);
        let udpIpMetaData = udpIpMetaAndDataStream.udpIpMetaDataOut.first;
        udpIpMetaAndDataStream.udpIpMetaDataOut.deq;
        dataStreamLengthBuf.enq(udpIpMetaData.dataLen + fromInteger(iCrcByteWidth));
        udpIpMetaDataBuf.enq(udpIpMetaData);
    endrule

    let udpIpMetaDataBuffered <- mkSizedFifoToPipeOut(
        valueOf(RDMA_META_BUF_SIZE),
        convertFifoToPipeOut(udpIpMetaDataBuf)
    );

    DataStreamPipeOut dataStreamWithOutICrc <- mkRemoveICrcFromDataStream(
        convertFifoToPipeOut(dataStreamLengthBuf),
        udpIpMetaAndDataStream.dataStreamOut
    );

    DataStreamPipeOut dataStreamBuffered <- mkSizedBramFifoToPipeOut(
        valueOf(RDMA_PAYLOAD_BUF_SIZE),
        dataStreamWithOutICrc
    );

    Reg#(Bool) isPassICrcCheck <- mkReg(False);
    Reg#(ICrcCheckState) iCrcCheckStateReg <- mkReg(ICRC_IDLE);
    FIFOF#(DataStream) dataStreamOutBuf <- mkFIFOF;
    FIFOF#(UdpIpMetaData) udpIpMetaDataOutBuf <- mkFIFOF;
    rule doCrcCheck;
        case(iCrcCheckStateReg) matches
            ICRC_IDLE: begin
                let crcChecksum = crc32Stream.first;
                crc32Stream.deq;
                $display("RdmaUdpIpEthRx gets iCRC result");
                if (crcChecksum == 0) begin
                    isPassICrcCheck <= True;
                    $display("Pass ICRC check");
                end
                else begin
                    isPassICrcCheck <= False;
                    $display("FAIL ICRC check");
                end
                iCrcCheckStateReg <= ICRC_META;
            end
            ICRC_META: begin
                let udpIpMetaData = udpIpMetaDataBuffered.first;
                udpIpMetaDataBuffered.deq;
                if (isPassICrcCheck) begin
                    udpIpMetaDataOutBuf.enq(udpIpMetaData);
                end
                iCrcCheckStateReg <= ICRC_PAYLOAD;
            end
            ICRC_PAYLOAD: begin
                let dataStream = dataStreamBuffered.first;
                dataStreamBuffered.deq;
                if (isPassICrcCheck) begin
                    dataStreamOutBuf.enq(dataStream);
                end
                if (dataStream.isLast) begin
                    iCrcCheckStateReg <= ICRC_IDLE;
                end
            end
        endcase
    endrule

    interface PipeOut udpIpMetaDataOut = convertFifoToPipeOut(udpIpMetaDataOutBuf);
    interface PipeOut dataStreamOut = convertFifoToPipeOut(dataStreamOutBuf);
endmodule
