module ahb_to_axi4 #(
  parameter AXI_ID_WIDTH   = 1,
  parameter AXI_ADDR_WIDTH = 64,
  parameter AXI_DATA_WIDTH = 64,
  parameter AXI_STRB_WIDTH = 1
)
  (
    input                   clk,
    input                   rst_l,

    input                   bus_clk_en,

    // AXI signals
    // AXI Write Channels
    output logic [AXI_ID_WIDTH  -1:0] axi_awid,
    output logic [AXI_ADDR_WIDTH-1:0] axi_awaddr,
    output logic [               7:0] axi_awlen,
    output logic [               2:0] axi_awsize,
    output logic [               1:0] axi_awburst,
    output logic [               2:0] axi_awprot,
    output logic                      axi_awvalid,
    input  logic                      axi_awready,

    output logic [AXI_DATA_WIDTH-1:0] axi_wdata,
    output logic [AXI_STRB_WIDTH-1:0] axi_wstrb,
    output logic                      axi_wlast,
    output logic                      axi_wvalid,
    input  logic                      axi_wready,

    input  logic [AXI_ID_WIDTH  -1:0] axi_bid,
    input  logic [               1:0] axi_bresp,
    input  logic                      axi_bvalid,
    output logic                      axi_bready,

    // AXI Read Channels
    output logic [AXI_ID_WIDTH  -1:0] axi_arid,
    output logic [AXI_ADDR_WIDTH-1:0] axi_araddr,
    output logic [               7:0] axi_arlen,
    output logic [               2:0] axi_arsize,
    output logic [               1:0] axi_arburst,
    output logic [               2:0] axi_arprot,
    output logic                      axi_arvalid,
    input  logic                      axi_arready,

    input  logic [AXI_ID_WIDTH  -1:0] axi_rid,
    input  logic [AXI_DATA_WIDTH-1:0] axi_rdata,
    input  logic [               1:0] axi_rresp,
    input  logic                      axi_rvalid,
    output logic                      axi_rready,

    // AHB-Lite signals
    input  logic [AHB_ADDR_WIDTH-1:0] ahb_haddr,     // ahb bus address
    input  logic [               2:0] ahb_hburst,    // tied to 0
    input  logic                      ahb_hmastlock, // tied to 0
    input  logic [               3:0] ahb_hprot,     // tied to 4'b0011
    input  logic [               2:0] ahb_hsize,     // size of bus transaction (possible values 0,1,2,3)
    input  logic [               1:0] ahb_htrans,    // Transaction type (possible values 0,2 only right now)
    input  logic                      ahb_hwrite,    // ahb bus write
    input  logic [AHB_DATA_WIDTH-1:0] ahb_hwdata,    // ahb bus write data
    input  logic                      ahb_hsel,      // this slave was selected
    input  logic                      ahb_hreadyin,  // previous hready was accepted or not

    output logic [AHB_DATA_WIDTH-1:0] ahb_hrdata,     // ahb bus read data
    output logic                      ahb_hreadyout,  // slave ready to accept transaction
    output logic                      ahb_hresp       // slave response (high indicates erro)
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

  logic                    ahb_hready;
  logic                    ahb_hready_q;
  logic [1:0]              ahb_htrans_in, ahb_htrans_q;
  logic [2:0]              ahb_hsize_q;
  logic                    ahb_hwrite_q;
  logic [31:0]             ahb_haddr_q;
  logic [63:0]             ahb_hwdata_q;
  logic                    ahb_hresp_q;

  //Miscellaneous signals
  logic                    ahb_addr_in_dccm, ahb_addr_in_iccm, ahb_addr_in_pic;
  logic                    ahb_addr_in_dccm_region_nc, ahb_addr_in_iccm_region_nc, ahb_addr_in_pic_region_nc;

  // signals needed for the read data coming back from the core and to block any further commands as AHB is a blocking bus
  logic                    buf_rdata_en;

  logic                    ahb_bus_addr_clk_en, buf_rdata_clk_en;
  logic                    ahb_clk, ahb_addr_clk, buf_rdata_clk;

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
        buf_nxtstate      = ahb_hwrite ? WR : RD;
        buf_state_en      = ahb_hready & ahb_htrans[1] & ahb_hsel;  // only transition on a valid hrtans
      end
      WR: begin // Write command recieved last cycle
        buf_nxtstate      = (ahb_hresp | (ahb_htrans[1:0] == 2'b0) | ~ahb_hsel) ? IDLE : (ahb_hwrite ? WR : RD);
        buf_state_en      = (~cmdbuf_full | ahb_hresp) ;
        cmdbuf_wr_en      = ~cmdbuf_full & ~(ahb_hresp | ((ahb_htrans[1:0] == 2'b01) & ahb_hsel));
        // Dont send command to the buffer in case of an error or when the master is not ready with the data now.
      end
      RD: begin // Read command recieved last cycle.
        buf_nxtstate      = ahb_hresp ? IDLE :PEND;      // If error go to idle, else wait for read data
        buf_state_en      = (~cmdbuf_full | ahb_hresp);  // only when command can go, or if its an error
        cmdbuf_wr_en      = ~ahb_hresp & ~cmdbuf_full;   // send command only when no error
      end
      PEND: begin // Read Command has been sent. Waiting on Data.
        buf_nxtstate      = IDLE;                            // go back for next command and present data next cycle
        buf_state_en      = axi_rvalid & ~cmdbuf_write;      // read data is back
        buf_rdata_en      = buf_state_en;                    // buffer the read data coming back from core
        buf_read_error_in = buf_state_en & |axi_rresp[1:0];  // buffer error flag if return has Error ( ECC )
      end
    endcase
  end // always_comb begin

  rvdffs #($bits(state_t)) state_reg (.*, .din(buf_nxtstate), .dout({buf_state}), .en(buf_state_en), .clk(ahb_clk));

  assign master_wstrb[7:0]   = ({8{ahb_hsize_q[2:0] == 3'b000}} & (8'b0000_0001 << ahb_haddr_q[2:0])) |
                               ({8{ahb_hsize_q[2:0] == 3'b001}} & (8'b0000_0011 << ahb_haddr_q[2:0])) |
                               ({8{ahb_hsize_q[2:0] == 3'b010}} & (8'b0000_1111 << ahb_haddr_q[2:0])) |
                               ({8{ahb_hsize_q[2:0] == 3'b011}} & (8'b1111_1111));

  // AHB signals
  assign ahb_hreadyout       = ahb_hresp ? (ahb_hresp_q & ~ahb_hready_q) :
    ((~cmdbuf_full | (buf_state == IDLE)) & ~(buf_state == RD | buf_state == PEND)  & ~buf_read_error);

  assign ahb_hready          = ahb_hreadyout & ahb_hreadyin;
  assign ahb_htrans_in[1:0]  = {2{ahb_hsel}} & ahb_htrans[1:0];
  assign ahb_hrdata[63:0]    = buf_rdata[63:0];
  assign ahb_hresp           = ((ahb_htrans_q[1:0] != 2'b0) & (buf_state != IDLE)  &
                               // request not for ICCM or DCCM
                               ((~(ahb_addr_in_dccm | ahb_addr_in_iccm)) |
                               // ICCM Rd/Wr OR DCCM Wr not the right size
                               ((ahb_addr_in_iccm | (ahb_addr_in_dccm &  ahb_hwrite_q)) & ~((ahb_hsize_q[1:0] == 2'b10) | (ahb_hsize_q[1:0] == 2'b11))) |
                               // HW size but unaligned
                               ((ahb_hsize_q[2:0] == 3'h1) & ahb_haddr_q[0]) |
                               // W size but unaligned
                               ((ahb_hsize_q[2:0] == 3'h2) & (|ahb_haddr_q[1:0])) |
                               // DW size but unaligned
                               ((ahb_hsize_q[2:0] == 3'h3) & (|ahb_haddr_q[2:0])))) |
                               // Read ECC error
                               buf_read_error |
                               // This is for second cycle of hresp protocol
                               (ahb_hresp_q & ~ahb_hready_q);

  // Buffer signals - needed for the read data and ECC error response
  always_ff @(posedge buf_rdata_clk or negedge rst_l) begin
    if (rst_l == 0)
      buf_rdata[63:0] <= 0;
    else
      buf_rdata[63:0] <= axi_rdata[63:0];
  end

  // buf_read_error will be high only one cycle
  always_ff @(posedge ahb_clk or negedge rst_l) begin
    if (rst_l == 0)
      buf_read_error <= 0;
    else
      buf_read_error <= buf_read_error_in;
  end

  // All the Master signals are captured before presenting it to the command buffer.
  // We check for Hresp before sending it to the cmd buffer.
  always_ff @(posedge ahb_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb_hresp_q <= 0;
    else
      ahb_hresp_q <= ahb_hresp;
  end

  always_ff @(posedge ahb_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb_hready_q <= 0;
    else
      ahb_hready_q <= ahb_hready;
  end

  always_ff @(posedge ahb_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb_htrans_q[1:0] <= 0;
    else
      ahb_htrans_q[1:0] <= ahb_htrans_in[1:0];
  end

  always_ff @(posedge ahb_addr_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb_hsize_q[2:0] <= 0;
    else
      ahb_hsize_q[2:0] <= ahb_hsize[2:0];
  end

  always_ff @(posedge ahb_addr_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb_hwrite_q <= 0;
    else
      ahb_hwrite_q <= ahb_hwrite;
  end

  always_ff @(posedge ahb_addr_clk or negedge rst_l) begin
    if (rst_l == 0)
      ahb_haddr_q[31:0] <= 0;
    else
      ahb_haddr_q[31:0] <= ahb_haddr[31:0];
  end

  // Clock header logic
  assign ahb_bus_addr_clk_en = bus_clk_en & (ahb_hready & ahb_htrans[1]);
  assign buf_rdata_clk_en    = bus_clk_en & buf_rdata_en;

  rvclkhdr ahb_cgc       (.en(bus_clk_en),          .l1clk(ahb_clk),       .*);
  rvclkhdr ahb_addr_cgc  (.en(ahb_bus_addr_clk_en), .l1clk(ahb_addr_clk),  .*);
  rvclkhdr buf_rdata_cgc (.en(buf_rdata_clk_en),    .l1clk(buf_rdata_clk), .*);

  // Address check  dccm
  assign ahb_addr_in_dccm_region_nc = (ahb_haddr_q[31:(32-REGION_BITS)] == `RV_DCCM_SADR[31:(32-REGION_BITS)]);

  if (`RV_DCCM_SIZE == 48) begin
    assign ahb_addr_in_dccm = (ahb_haddr_q[31:MASK_BITS] == `RV_DCCM_SADR[31:MASK_BITS]) & ~(&ahb_haddr_q[MASK_BITS-1 : MASK_BITS-2]);
  end
  else begin
    assign ahb_addr_in_dccm = (ahb_haddr_q[31:MASK_BITS] == `RV_DCCM_SADR[31:MASK_BITS]);
  end

  // Address check  iccm
  assign ahb_addr_in_iccm_region_nc = (ahb_haddr_q[31:(32-REGION_BITS)] == `RV_ICCM_SADR[31:(32-REGION_BITS)]);

  if (`RV_ICCM_SIZE == 48) begin
    assign ahb_addr_in_iccm = (ahb_haddr_q[31:MASK_BITS] == `RV_ICCM_SADR[31:MASK_BITS]) & ~(&ahb_haddr_q[MASK_BITS-1 : MASK_BITS-2]);
  end
  else begin
    assign ahb_addr_in_iccm = (ahb_haddr_q[31:MASK_BITS] == `RV_ICCM_SADR[31:MASK_BITS]);
  end
  `else
  assign ahb_addr_in_iccm = '0;
  assign ahb_addr_in_iccm_region_nc = '0;
  `endif

  // PIC memory address check
  assign ahb_addr_in_pic_region_nc = (ahb_haddr_q[31:(32-REGION_BITS)] == `RV_PIC_BASE_ADDR[31:(32-REGION_BITS)]);

  if (`RV_PIC_SIZE == 48) begin
    assign ahb_addr_in_pic = (ahb_haddr_q[31:MASK_BITS] == `RV_PIC_BASE_ADDR[31:MASK_BITS]) & ~(&ahb_haddr_q[MASK_BITS-1 : MASK_BITS-2]);
  end
  else begin
    assign ahb_addr_in_pic = (ahb_haddr_q[31:MASK_BITS] == `RV_PIC_BASE_ADDR[31:MASK_BITS]);
  end

  // Command Buffer
  // Holding for the commands to be sent for the AXI. It will be converted to the AXI signals.
  assign cmdbuf_rst         = (((axi_awvalid & axi_awready) | (axi_arvalid & axi_arready)) & ~cmdbuf_wr_en) | (ahb_hresp & ~cmdbuf_write);
  assign cmdbuf_full        = (cmdbuf_vld & ~((axi_awvalid & axi_awready) | (axi_arvalid & axi_arready)));

  rvdffsc #(.WIDTH(1))   cmdbuf_vldff      (.din(1'b1),                .dout(cmdbuf_vld),          .en(cmdbuf_wr_en),   .clear(cmdbuf_rst),      .clk(bus_clk), .*);
  rvdffs  #(.WIDTH(1))   cmdbuf_writeff    (.din(ahb_hwrite_q),        .dout(cmdbuf_write),        .en(cmdbuf_wr_en),   .clk(bus_clk), .*);
  rvdffs  #(.WIDTH(2))   cmdbuf_sizeff     (.din(ahb_hsize_q[1:0]),    .dout(cmdbuf_size[1:0]),    .en(cmdbuf_wr_en),   .clk(bus_clk), .*);
  rvdffs  #(.WIDTH(8))   cmdbuf_wstrbff    (.din(master_wstrb[7:0]),   .dout(cmdbuf_wstrb[7:0]),   .en(cmdbuf_wr_en),   .clk(bus_clk), .*);
  rvdffe  #(.WIDTH(32))  cmdbuf_addrff     (.din(ahb_haddr_q[31:0]),   .dout(cmdbuf_addr[31:0]),   .en(cmdbuf_wr_en),   .clk(bus_clk), .*);
  rvdffe  #(.WIDTH(64))  cmdbuf_wdataff    (.din(ahb_hwdata[63:0]),    .dout(cmdbuf_wdata[63:0]),  .en(cmdbuf_wr_en),   .clk(bus_clk), .*);

  // AXI Write Command Channel
  assign axi_awvalid           = cmdbuf_vld & cmdbuf_write;
  assign axi_awid[TAG-1:0]     = '0;
  assign axi_awaddr[31:0]      = cmdbuf_addr[31:0];
  assign axi_awsize[2:0]       = {1'b0, cmdbuf_size[1:0]};
  assign axi_awprot[2:0]       = 3'b0;
  assign axi_awlen[7:0]        = '0;
  assign axi_awburst[1:0]      = 2'b01;

  // AXI Write Data Channel
  // This is tied to the command channel as we only write the command buffer once we have the data.
  assign axi_wvalid            = cmdbuf_vld & cmdbuf_write;
  assign axi_wdata[63:0]       = cmdbuf_wdata[63:0];
  assign axi_wstrb[7:0]        = cmdbuf_wstrb[7:0];
  assign axi_wlast             = 1'b1;

  // AXI Write Response
  // Always ready. AHB does not require a write response.
  assign axi_bready            = 1'b1;

  // AXI Read Channels
  assign axi_arvalid           = cmdbuf_vld & ~cmdbuf_write;
  assign axi_arid[TAG-1:0]     = '0;
  assign axi_araddr[31:0]      = cmdbuf_addr[31:0];
  assign axi_arsize[2:0]       = {1'b0, cmdbuf_size[1:0]};
  assign axi_arprot            = 3'b0;
  assign axi_arlen[7:0]        = '0;
  assign axi_arburst[1:0]      = 2'b01;

  // AXI Read Response Channel
  // Always ready as AHB reads are blocking and the the buffer is available for the read coming back always.
  assign axi_rready            = 1'b1;

  // Clock header logic
  rvclkhdr bus_cgc        (.en(bus_clk_en),       .l1clk(bus_clk),       .*);
endmodule
