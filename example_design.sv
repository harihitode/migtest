// [hardware jikken 8]
// user side test-bench code for memory simulator
// FIX: 2017/03/09 (incorrect timing for wlast flag)

module example_top
  #(
    parameter DQ_WIDTH = 16,
    parameter DQS_WIDTH = 2,
    parameter ROW_WIDTH = 13,
    parameter BANK_WIDTH = 3,
    parameter CK_WIDTH = 1,
    parameter CKE_WIDTH = 1,
    parameter DM_WIDTH = 1,
    parameter ODT_WIDTH = 1
    )
  (
   inout [DQ_WIDTH-1:0]    ddr2_dq,
   inout [DQS_WIDTH-1:0]   ddr2_dqs_n,
   inout [DQS_WIDTH-1:0]   ddr2_dqs_p,
   output [ROW_WIDTH-1:0]  ddr2_addr,
   output [BANK_WIDTH-1:0] ddr2_ba,
   output                  ddr2_ras_n,
   output                  ddr2_cas_n,

   output                  ddr2_we_n,
   output [CK_WIDTH-1:0]   ddr2_ck_p,
   output [CK_WIDTH-1:0]   ddr2_ck_n,
   output [CKE_WIDTH-1:0]  ddr2_cke,
   output                  ddr2_cs_n,
   output [DM_WIDTH-1:0]   ddr2_dm,
   output [ODT_WIDTH-1:0]  ddr2_odt,

   input                   sys_clk_i,
   input                   clk_ref_i,
   input                   init_calib_complete,
   output                  tg_compare_error,
   input                   sys_rst
   );

   // burst parameter
   parameter beats_per_burst = 15; // you can modify this by 0 ~ 255
   // user error
   assign tg_compare_error = 0;

   // user interface signals
   logic                          ui_clk; // 333.333 / 4 [MHz]
   logic                          ui_clk_sync_rst, mmcm_locked, app_sr_active, app_ref_ack, app_zq_ack;

   // constants
   logic                          aresetn = 1'b1; // not used
   logic                          app_sr_req = 1'b0; // not used
   logic                          app_ref_req = 1'b0; // not used
   logic                          app_zq_req = 1'b0; // not used

   // constant (for write)
   logic [7:0]                    s_axi_awlen = beats_per_burst; // not send multiple beats
   logic [2:0]                    s_axi_awsize = 3'b100; // beat width 2^4=16byte
   logic [1:0]                    s_axi_awburst = 2'b01; // incremental burst
   logic [0:0]                    s_axi_awlock = 1'b0; // (non) exclusive
   logic [3:0]                    s_axi_awcache = 4'b0011; // recommended 0011
   logic [2:0]                    s_axi_awprot = 3'b000; // recommended 000
   logic [3:0]                    s_axi_awqos = 4'h0; // not implemented

   // for write (address)
   logic [1:0]                    s_axi_awid = 2'b01;
   logic [27:0]                   s_axi_awaddr;
   logic                          s_axi_awvalid = 0;
   logic                          s_axi_awready;

   // for write (data)
   logic [127:0]                  s_axi_wdata;
   logic [15:0]                   s_axi_wstrb = 16'hffff; // for write strobe (example: all on)
   logic                          s_axi_wlast = 0;
   logic                          s_axi_wvalid = 0;
   logic                          s_axi_wready;

   // for write (response)
   logic [1:0]                    s_axi_bid; // response to s_axi_awid
   logic [1:0]                    s_axi_bresp;
   logic                          s_axi_bvalid;
   logic                          s_axi_bready = 0;

   // constant (for read)
   logic [7:0]                    s_axi_arlen = beats_per_burst; // not send multiple beats
   logic [2:0]                    s_axi_arsize = 3'b100; // beat width 2^4=16byte
   logic [1:0]                    s_axi_arburst = 2'b01; // incremental burst
   logic [0:0]                    s_axi_arlock = 1'b0; // (non) exclusive
   logic [3:0]                    s_axi_arcache = 4'b0011; // recommended 0011
   logic [2:0]                    s_axi_arprot = 3'b000; // recommended 000
   logic [3:0]                    s_axi_arqos = 4'h0; // not implemented

   // for read (address)
   logic [1:0]                    s_axi_arid = 2'b01;
   logic [27:0]                   s_axi_araddr = 28'b0;
   logic                          s_axi_arvalid = 0;
   logic                          s_axi_arready;

   // for read (data)
   logic [1:0]                    s_axi_rid; // response to s_axi_arid
   logic [127:0]                  s_axi_rdata;
   logic [1:0]                    s_axi_rresp;
   logic                          s_axi_rlast;
   logic                          s_axi_rready = 0;
   logic                          s_axi_rvalid;

   // state
   integer                        state = INITIAL_STATE;

   // STATE_FLOW
   parameter INITIAL_STATE = 0;
   parameter WRITE_ADDRESS_SEND_VALID = INITIAL_STATE + 1;
   parameter WRITE_ADDRESS_WAIT_READY = WRITE_ADDRESS_SEND_VALID + 1;
   parameter WRITE_FIRST_DATA = WRITE_ADDRESS_WAIT_READY + 1;
   parameter WRITE_LAST_DATA =  WRITE_FIRST_DATA + beats_per_burst;
   parameter WRITE_RESPONSE_WAIT = WRITE_LAST_DATA + 1;
   parameter READ_ADDRESS_SEND_VALID = WRITE_RESPONSE_WAIT + 1;
   parameter READ_ADDRESS_WAIT_READY = READ_ADDRESS_SEND_VALID + 1;
   parameter READ_DATA = READ_ADDRESS_WAIT_READY + 1;
   parameter FINAL_STATE = READ_DATA + 1;

   // initialize
   always_comb
     if (init_calib_complete == 1) state <= WRITE_ADDRESS_SEND_VALID;

   assign s_axi_wdata = {104'b0, 16'hCAFE, s_axi_awaddr[7:0]};

   always_ff @(posedge ui_clk)
     begin
        if (state == WRITE_ADDRESS_SEND_VALID) begin
           s_axi_awaddr <= 28'b0;
           s_axi_awvalid <= 1;
           state <= WRITE_ADDRESS_WAIT_READY;
        end
        else if (state == WRITE_ADDRESS_WAIT_READY) begin
           if (s_axi_awvalid & s_axi_awready) begin
              s_axi_awvalid <= 0;
              state <= WRITE_FIRST_DATA;
              // prepare first data
              s_axi_wvalid <= 1;
              if (WRITE_FIRST_DATA == WRITE_LAST_DATA)
                s_axi_wlast <= 1;
              else s_axi_wlast <= 0;
           end
        end
        else if (state >= WRITE_FIRST_DATA && state <= WRITE_LAST_DATA) begin
           if (s_axi_wvalid & s_axi_wready) begin
              s_axi_awaddr <= s_axi_awaddr + 1; // changing for data
              s_axi_wvalid <= 1;
              if (state == WRITE_LAST_DATA) begin
                 state <= WRITE_RESPONSE_WAIT;
                 s_axi_wlast <= 0;
                 s_axi_wvalid <= 0;
                 s_axi_bready <= 1;
              end
              else if (state == WRITE_LAST_DATA - 1) begin
                 s_axi_wlast <= 1;
                 state <= state + 1;
              end
              else begin
                 state <= state + 1;
              end
           end
        end
        else if (state == WRITE_RESPONSE_WAIT) begin
           if (s_axi_bvalid & s_axi_bready) begin
              s_axi_bready <= 0;
              state <= READ_ADDRESS_SEND_VALID;
           end
        end
        else if (state == READ_ADDRESS_SEND_VALID) begin
           s_axi_arvalid <= 1;
           state <= READ_ADDRESS_WAIT_READY;
        end
        else if (state == READ_ADDRESS_WAIT_READY) begin
           if (s_axi_arvalid & s_axi_arready) begin
              s_axi_arvalid <= 0;
              s_axi_rready <= 1;
              state <= READ_DATA;
           end
        end
        else if (state == READ_DATA) begin
           if (s_axi_rvalid & s_axi_rready) begin
              if (s_axi_rlast) begin
                 s_axi_rready <= 0;
                 state <= FINAL_STATE;
              end
           end
        end
     end
  memory_interface INST(.*);

endmodule
