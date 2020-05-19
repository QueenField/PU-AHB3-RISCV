////////////////////////////////////////////////////////////////////////////////
//                                            __ _      _     _               //
//                                           / _(_)    | |   | |              //
//                __ _ _   _  ___  ___ _ __ | |_ _  ___| | __| |              //
//               / _` | | | |/ _ \/ _ \ '_ \|  _| |/ _ \ |/ _` |              //
//              | (_| | |_| |  __/  __/ | | | | | |  __/ | (_| |              //
//               \__, |\__,_|\___|\___|_| |_|_| |_|\___|_|\__,_|              //
//                  | |                                                       //
//                  |_|                                                       //
//                                                                            //
//                                                                            //
//              MPSoC-RISCV CPU                                               //
//              AMBA3 AHB-Lite Bus Interface                                  //
//              AMBA4 AXI-Lite Bus Interface                                  //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

/* Copyright (c) 2017-2018 by the author(s)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 * =============================================================================
 * Author(s):
 *   Francisco Javier Reina Campo <frareicam@gmail.com>
 */

module riscv_ahb2axi #(
  parameter AXI_ID_WIDTH   = 10,
  parameter AXI_ADDR_WIDTH = 64,
  parameter AXI_DATA_WIDTH = 64,
  parameter AXI_STRB_WIDTH = 10,

  parameter AHB_ADDR_WIDTH = 64,
  parameter AHB_DATA_WIDTH = 64
)
  (
    input                   clk,
    input                   rst_l,

    input                   bus_clk_en,

    // AXI4 signals
    output logic [AXI_ID_WIDTH  -1:0] axi4_aw_id,
    output logic [AXI_ADDR_WIDTH-1:0] axi4_aw_addr,
    output logic [               7:0] axi4_aw_len,
    output logic [               2:0] axi4_aw_size,
    output logic [               1:0] axi4_aw_burst,
    output logic [               2:0] axi4_aw_prot,
    output logic                      axi4_aw_valid,
    input  logic                      axi4_aw_ready,

    output logic [AXI_ID_WIDTH  -1:0] axi4_ar_id,
    output logic [AXI_ADDR_WIDTH-1:0] axi4_ar_addr,
    output logic [               7:0] axi4_ar_len,
    output logic [               2:0] axi4_ar_size,
    output logic [               1:0] axi4_ar_burst,
    output logic [               2:0] axi4_ar_prot,
    output logic                      axi4_ar_valid,
    input  logic                      axi4_ar_ready,

    output logic [AXI_DATA_WIDTH-1:0] axi4_w_data,
    output logic [AXI_STRB_WIDTH-1:0] axi4_w_strb,
    output logic                      axi4_w_last,
    output logic                      axi4_w_valid,
    input  logic                      axi4_w_ready,

    input  logic [AXI_ID_WIDTH  -1:0] axi4_r_id,
    input  logic [AXI_DATA_WIDTH-1:0] axi4_r_data,
    input  logic [               1:0] axi4_r_resp,
    input  logic                      axi4_r_valid,
    output logic                      axi4_r_ready,

    input  logic [AXI_ID_WIDTH  -1:0] axi4_b_id,
    input  logic [               1:0] axi4_b_resp,
    input  logic                      axi4_b_valid,
    output logic                      axi4_b_ready,

    // AHB3 signals
    input  logic                      ahb3_hsel,
    input  logic [AHB_ADDR_WIDTH-1:0] ahb3_haddr,
    input  logic [AHB_DATA_WIDTH-1:0] ahb3_hwdata,
    output logic [AHB_DATA_WIDTH-1:0] ahb3_hrdata,
    input  logic                      ahb3_hwrite,
    input  logic [               2:0] ahb3_hsize,
    input  logic [               2:0] ahb3_hburst,
    input  logic [               3:0] ahb3_hprot,
    input  logic [               1:0] ahb3_htrans,
    input  logic                      ahb3_hmastlock,
    input  logic                      ahb3_hreadyin,
    output logic                      ahb3_hreadyout,
    output logic                      ahb3_hresp
  );

  localparam REGION_BITS = 4;
  localparam MASK_BITS   = 10 + $clog2(`RV_PIC_SIZE);

  logic [7:0]       master_wstrb;

  typedef enum logic [1:0] { IDLE   = 2'b00,    // Nothing in the buffer. No commands yet recieved
                             WR     = 2'b01,    // Write Command recieved
                             RD     = 2'b10,    // Read Command recieved
                             PEND   = 2'b11     // Waiting on Read Data from core
                           } state_t;
  state_t      buf_state, buf_nxtstate;
  logic        buf_state_en;

  // Buffer signals (one entry buffer)
  logic                    buf_read_error_in, buf_read_error;
  logic [63:0]             buf_rdata;

  logic                    ahb3_hready;
  logic                    ahb3_hready_q;
  logic [1:0]              ahb3_htrans_in, ahb3_htrans_q;
  logic [2:0]              ahb3_hsize_q;
  logic                    ahb3_hwrite_q;
  logic [31:0]             ahb3_haddr_q;
  logic [63:0]             ahb3_hwdata_q;
  logic                    ahb3_hresp_q;

  //Miscellaneous signals
  logic                    ahb3_addr_in_dccm, ahb3_addr_in_iccm, ahb3_addr_in_pic;
  logic                    ahb3_addr_in_dccm_region_nc, ahb3_addr_in_iccm_region_nc, ahb3_addr_in_pic_region_nc;

  // signals needed for the read data coming back from the core and to block any further commands as AHB is a blocking bus
  logic                    buf_rdata_en;

  logic                    ahb3_bus_addr_clk_en, buf_rdata_clk_en;
  logic                    ahb3_clk, ahb3_addr_clk, buf_rdata_clk;

  // Command buffer is the holding station where we convert to AXI and send to core
  logic                    cmdbuf_wr_en, cmdbuf_rst;
  logic                    cmdbuf_full;
  logic                    cmdbuf_vld, cmdbuf_write;
  logic [1:0]              cmdbuf_size;
  logic [7:0]              cmdbuf_wstrb;
  logic [31:0]             cmdbuf_addr;
  logic [63:0]             cmdbuf_wdata;

  logic                    bus_clk;

  // FSM to control the bus states and when to block the hready and load the command buffer
  always_comb begin
    buf_nxtstate      = IDLE;
    buf_state_en      = 1'b0;
    buf_rdata_en      = 1'b0;  // signal to load the buffer when the core sends read data back
    buf_read_error_in = 1'b0;  // signal indicating that an error came back with the read from the core
    cmdbuf_wr_en      = 1'b0;  // all clear from the gasket to load the buffer with the command for reads, command/dat for writes
    case (buf_state)
      IDLE: begin  // No commands recieved
        buf_nxtstate      = ahb3_hwrite ? WR : RD;
        buf_state_en      = ahb3_hready & ahb3_htrans[1] & ahb3_hsel;  // only transition on a valid hrtans
      end
      WR: begin // Write command recieved last cycle
        buf_nxtstate      = (ahb3_hresp | (ahb3_htrans[1:0] == 2'b0) | ~ahb3_hsel) ? IDLE : (ahb3_hwrite ? WR : RD);
        buf_state_en      = (~cmdbuf_full | ahb3_hresp) ;
        cmdbuf_wr_en      = ~cmdbuf_full & ~(ahb3_hresp | ((ahb3_htrans[1:0] == 2'b01) & ahb3_hsel));
        // Dont send command to the buffer in case of an error or when the master is not ready with the data now.
      end
      RD: begin // Read command recieved last cycle.
        buf_nxtstate      = ahb3_hresp ? IDLE :PEND;      // If error go to idle, else wait for read data
        buf_state_en      = (~cmdbuf_full | ahb3_hresp);  // only when command can go, or if its an error
        cmdbuf_wr_en      = ~ahb3_hresp & ~cmdbuf_full;   // send command only when no error
      end
      PEND: begin // Read Command has been sent. Waiting on Data.
        buf_nxtstate      = IDLE;                            // go back for next command and present data next cycle
        buf_state_en      = axi4_r_valid & ~cmdbuf_write;      // read data is back
        buf_rdata_en      = buf_state_en;                    // buffer the read data coming back from core
        buf_read_error_in = buf_state_en & |axi4_r_resp[1:0];  // buffer error flag if return has Error ( ECC )
      end
    endcase
  end // always_comb begin

  rvdffs #($bits(state_t)) state_reg (.*, .din(buf_nxtstate), .dout({buf_state}), .en(buf_state_en), .clk(ahb3_clk));

  assign master_wstrb[7:0]   = ({8{ahb3_hsize_q[2:0] == 3'b000}} & (8'b0000_0001 << ahb3_haddr_q[2:0])) |
                               ({8{ahb3_hsize_q[2:0] == 3'b001}} & (8'b0000_0011 << ahb3_haddr_q[2:0])) |
                               ({8{ahb3_hsize_q[2:0] == 3'b010}} & (8'b0000_1111 << ahb3_haddr_q[2:0])) |
                               ({8{ahb3_hsize_q[2:0] == 3'b011}} & (8'b1111_1111));

  // AHB signals
  assign ahb3_hreadyout       = ahb3_hresp ? (ahb3_hresp_q & ~ahb3_hready_q) :
    ((~cmdbuf_full | (buf_state == IDLE)) & ~(buf_state == RD | buf_state == PEND)  & ~buf_read_error);

  assign ahb3_hready          = ahb3_hreadyout & ahb3_hreadyin;
  assign ahb3_htrans_in[1:0]  = {2{ahb3_hsel}} & ahb3_htrans[1:0];
  assign ahb3_hrdata[63:0]    = buf_rdata[63:0];
  assign ahb3_hresp           = ((ahb3_htrans_q[1:0] != 2'b0) & (buf_state != IDLE)  &
                               // request not for ICCM or DCCM
                               ((~(ahb3_addr_in_dccm | ahb3_addr_in_iccm)) |
                               // ICCM Rd/Wr OR DCCM Wr not the right size
                               ((ahb3_addr_in_iccm | (ahb3_addr_in_dccm &  ahb3_hwrite_q)) & ~((ahb3_hsize_q[1:0] == 2'b10) | (ahb3_hsize_q[1:0] == 2'b11))) |
                               // HW size but unaligned
                               ((ahb3_hsize_q[2:0] == 3'h1) & ahb3_haddr_q[0]) |
                               // W size but unaligned
                               ((ahb3_hsize_q[2:0] == 3'h2) & (|ahb3_haddr_q[1:0])) |
                               // DW size but unaligned
                               ((ahb3_hsize_q[2:0] == 3'h3) & (|ahb3_haddr_q[2:0])))) |
                               // Read ECC error
                               buf_read_error |
                               // This is for second cycle of hresp protocol
                               (ahb3_hresp_q & ~ahb3_hready_q);

  // Buffer signals - needed for the read data and ECC error response
  always_ff @(posedge buf_rdata_clk or negedge rst_l) begin
    if (rst_l == 0)
      buf_rdata[63:0] <= 0;
    else
      buf_rdata[63:0] <= axi4_r_data[63:0];
  end

  // buf_read_error will be high only one cycle
  always_ff @(posedge ahb3_clk or negedge rst_l) begin
    if (rst_l == 0)
      buf_read_error <= 0;
    else
      buf_read_error <= buf_read_error_in;
  end

  // All the Master signals are captured before presenting it to the command buffer.
  // We check for Hresp before sending it to the cmd buffer.
  always_ff @(posedge ahb3_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb3_hresp_q <= 0;
    else
      ahb3_hresp_q <= ahb3_hresp;
  end

  always_ff @(posedge ahb3_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb3_hready_q <= 0;
    else
      ahb3_hready_q <= ahb3_hready;
  end

  always_ff @(posedge ahb3_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb3_htrans_q[1:0] <= 0;
    else
      ahb3_htrans_q[1:0] <= ahb3_htrans_in[1:0];
  end

  always_ff @(posedge ahb3_addr_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb3_hsize_q[2:0] <= 0;
    else
      ahb3_hsize_q[2:0] <= ahb3_hsize[2:0];
  end

  always_ff @(posedge ahb3_addr_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb3_hwrite_q <= 0;
    else
      ahb3_hwrite_q <= ahb3_hwrite;
  end

  always_ff @(posedge ahb3_addr_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb3_haddr_q[31:0] <= 0;
    else
      ahb3_haddr_q[31:0] <= ahb3_haddr[31:0];
  end

  // Clock header logic
  assign ahb3_bus_addr_clk_en = bus_clk_en & (ahb3_hready & ahb3_htrans[1]);
  assign buf_rdata_clk_en    = bus_clk_en & buf_rdata_en;

  rvclkhdr ahb3_cgc       (.en(bus_clk_en),          .l1clk(ahb3_clk),       .*);
  rvclkhdr ahb3_addr_cgc  (.en(ahb3_bus_addr_clk_en), .l1clk(ahb3_addr_clk),  .*);
  rvclkhdr buf_rdata_cgc (.en(buf_rdata_clk_en),    .l1clk(buf_rdata_clk), .*);

  // Address check  dccm
  assign ahb3_addr_in_dccm_region_nc = (ahb3_haddr_q[31:(32-REGION_BITS)] == `RV_DCCM_SADR[31:(32-REGION_BITS)]);

  if (`RV_DCCM_SIZE == 48) begin
    assign ahb3_addr_in_dccm = (ahb3_haddr_q[31:MASK_BITS] == `RV_DCCM_SADR[31:MASK_BITS]) & ~(&ahb3_haddr_q[MASK_BITS-1 : MASK_BITS-2]);
  end
  else begin
    assign ahb3_addr_in_dccm = (ahb3_haddr_q[31:MASK_BITS] == `RV_DCCM_SADR[31:MASK_BITS]);
  end

  // Address check  iccm
  assign ahb3_addr_in_iccm_region_nc = (ahb3_haddr_q[31:(32-REGION_BITS)] == `RV_ICCM_SADR[31:(32-REGION_BITS)]);

  if (`RV_ICCM_SIZE == 48) begin
    assign ahb3_addr_in_iccm = (ahb3_haddr_q[31:MASK_BITS] == `RV_ICCM_SADR[31:MASK_BITS]) & ~(&ahb3_haddr_q[MASK_BITS-1 : MASK_BITS-2]);
  end
  else begin
    assign ahb3_addr_in_iccm = (ahb3_haddr_q[31:MASK_BITS] == `RV_ICCM_SADR[31:MASK_BITS]);
  end
  `else
  assign ahb3_addr_in_iccm = '0;
  assign ahb3_addr_in_iccm_region_nc = '0;
  `endif

  // PIC memory address check
  assign ahb3_addr_in_pic_region_nc = (ahb3_haddr_q[31:(32-REGION_BITS)] == `RV_PIC_BASE_ADDR[31:(32-REGION_BITS)]);

  if (`RV_PIC_SIZE == 48) begin
    assign ahb3_addr_in_pic = (ahb3_haddr_q[31:MASK_BITS] == `RV_PIC_BASE_ADDR[31:MASK_BITS]) & ~(&ahb3_haddr_q[MASK_BITS-1 : MASK_BITS-2]);
  end
  else begin
    assign ahb3_addr_in_pic = (ahb3_haddr_q[31:MASK_BITS] == `RV_PIC_BASE_ADDR[31:MASK_BITS]);
  end

  // Command Buffer
  // Holding for the commands to be sent for the AXI. It will be converted to the AXI signals.
  assign cmdbuf_rst         = (((axi4_aw_valid & axi4_aw_ready) | (axi4_ar_valid & axi4_ar_ready)) & ~cmdbuf_wr_en) | (ahb3_hresp & ~cmdbuf_write);
  assign cmdbuf_full        = (cmdbuf_vld & ~((axi4_aw_valid & axi4_aw_ready) | (axi4_ar_valid & axi4_ar_ready)));

  rvdffsc #(.WIDTH(1))   cmdbuf_vldff      (.din(1'b1),                .dout(cmdbuf_vld),          .en(cmdbuf_wr_en),   .clear(cmdbuf_rst),      .clk(bus_clk), .*);
  rvdffs  #(.WIDTH(1))   cmdbuf_writeff    (.din(ahb3_hwrite_q),        .dout(cmdbuf_write),        .en(cmdbuf_wr_en),   .clk(bus_clk), .*);
  rvdffs  #(.WIDTH(2))   cmdbuf_sizeff     (.din(ahb3_hsize_q[1:0]),    .dout(cmdbuf_size[1:0]),    .en(cmdbuf_wr_en),   .clk(bus_clk), .*);
  rvdffs  #(.WIDTH(8))   cmdbuf_wstrbff    (.din(master_wstrb[7:0]),   .dout(cmdbuf_wstrb[7:0]),   .en(cmdbuf_wr_en),   .clk(bus_clk), .*);
  rvdffe  #(.WIDTH(32))  cmdbuf_addrff     (.din(ahb3_haddr_q[31:0]),   .dout(cmdbuf_addr[31:0]),   .en(cmdbuf_wr_en),   .clk(bus_clk), .*);
  rvdffe  #(.WIDTH(64))  cmdbuf_wdataff    (.din(ahb3_hwdata[63:0]),    .dout(cmdbuf_wdata[63:0]),  .en(cmdbuf_wr_en),   .clk(bus_clk), .*);

  // AXI Write Command Channel
  assign axi4_aw_valid           = cmdbuf_vld & cmdbuf_write;
  assign axi4_aw_id[TAG-1:0]     = '0;
  assign axi4_aw_addr[31:0]      = cmdbuf_addr[31:0];
  assign axi4_aw_size[2:0]       = {1'b0, cmdbuf_size[1:0]};
  assign axi4_aw_prot[2:0]       = 3'b0;
  assign axi4_aw_len[7:0]        = '0;
  assign axi4_aw_burst[1:0]      = 2'b01;

  // AXI Write Data Channel
  // This is tied to the command channel as we only write the command buffer once we have the data.
  assign axi4_w_valid            = cmdbuf_vld & cmdbuf_write;
  assign axi4_w_data[63:0]       = cmdbuf_wdata[63:0];
  assign axi4_w_strb[7:0]        = cmdbuf_wstrb[7:0];
  assign axi4_w_last             = 1'b1;

  // AXI Write Response
  // Always ready. AHB does not require a write response.
  assign axi4_b_ready            = 1'b1;

  // AXI Read Channels
  assign axi4_ar_valid           = cmdbuf_vld & ~cmdbuf_write;
  assign axi4_ar_id[TAG-1:0]     = '0;
  assign axi4_ar_addr[31:0]      = cmdbuf_addr[31:0];
  assign axi4_ar_size[2:0]       = {1'b0, cmdbuf_size[1:0]};
  assign axi4_ar_prot            = 3'b0;
  assign axi4_ar_len[7:0]        = '0;
  assign axi4_ar_burst[1:0]      = 2'b01;

  // AXI Read Response Channel
  // Always ready as AHB reads are blocking and the the buffer is available for the read coming back always.
  assign axi4_r_ready            = 1'b1;

  // Clock header logic
  rvclkhdr bus_cgc        (.en(bus_clk_en),       .l1clk(bus_clk),       .*);
endmodule
