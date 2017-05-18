// Author: Florian Zaruba, ETH Zurich
// Date: 19.04.2017
// Description: Load Store Unit, handles address calculation and memory interface signals
//
// Copyright (C) 2017 ETH Zurich, University of Bologna
// All rights reserved.
//
// This code is under development and not yet released to the public.
// Until it is released, the code is under the copyright of ETH Zurich and
// the University of Bologna, and may contain confidential and/or unpublished
// work. Any reuse/redistribution is strictly forbidden without written
// permission from ETH Zurich.
//
// Bug fixes and contributions will eventually be released under the
// SolderPad open hardware license in the context of the PULP platform
// (http://www.pulp-platform.org), under the copyright of ETH Zurich and the
// University of Bologna.
//
import ariane_pkg::*;

module lsu #(
    parameter int ASID_WIDTH = 1
    )(
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     flush_i,

    input  fu_op                     operator_i,
    input  logic [63:0]              operand_a_i,
    input  logic [63:0]              operand_b_i,
    input  logic [63:0]              imm_i,
    output logic                     lsu_ready_o,              // FU is ready e.g. not busy
    input  logic                     lsu_valid_i,              // Input is valid
    input  logic [TRANS_ID_BITS-1:0] trans_id_i,               // transaction id, needed for WB
    output logic [TRANS_ID_BITS-1:0] lsu_trans_id_o,           // ID of scoreboard entry at which to write back
    output logic [63:0]              lsu_result_o,
    output logic                     lsu_valid_o,              // transaction id for which the output is the requested one
    input  logic                     commit_i,                 // commit the pending store

    input  logic                     enable_translation_i,     // enable virtual memory translation

    input  logic                     fetch_req_i,              // Instruction fetch interface
    output logic                     fetch_gnt_o,              // Instruction fetch interface
    output logic                     fetch_valid_o,            // Instruction fetch interface
    output logic                     fetch_err_o,              // Instruction fetch interface
    input  logic [63:0]              fetch_vaddr_i,            // Instruction fetch interface
    output logic [31:0]              fetch_rdata_o,            // Instruction fetch interface

    input  priv_lvl_t                priv_lvl_i,               // From CSR register file
    input  logic                     flag_pum_i,               // From CSR register file
    input  logic                     flag_mxr_i,               // From CSR register file
    input  logic [37:0]              pd_ppn_i,                 // From CSR register file
    input  logic [ASID_WIDTH-1:0]    asid_i,                   // From CSR register file
    input  logic                     flush_tlb_i,
     // Instruction memory/cache
    output logic [63:0]              instr_if_address_o,
    output logic                     instr_if_data_req_o,
    output logic [3:0]               instr_if_data_be_o,
    input  logic                     instr_if_data_gnt_i,
    input  logic                     instr_if_data_rvalid_i,
    input  logic [31:0]              instr_if_data_rdata_i,
    // Data memory/cache
    output logic [63:0]              data_if_address_o,
    output logic [63:0]              data_if_data_wdata_o,
    output logic                     data_if_data_req_o,
    output logic                     data_if_data_we_o,
    output logic [7:0]               data_if_data_be_o,
    output logic [1:0]               data_if_tag_status_o,
    input  logic                     data_if_data_gnt_i,
    input  logic                     data_if_data_rvalid_i,
    input  logic [63:0]              data_if_data_rdata_i,

    output exception                 lsu_exception_o   // to WB, signal exception status LD/ST exception

);
    // tag status
    enum logic [1:0] { WAIT_TRANSLATION, ABORT_TRANSLATION, VALID_TRANSLATION, NOT_IMPL } tag_status;

    mem_if ptw_if(clk_i);
    // byte enable based on operation to perform
    // data is misaligned
    logic data_misaligned;

    enum logic [2:0] { IDLE, STORE, LOAD_WAIT_TRANSLATION, LOAD_WAIT_GNT, LOAD_WAIT_RVALID } CS, NS;

    // virtual address as calculated by the AGU in the first cycle
    logic [63:0] vaddr_i;
    // gets the data from the register
    logic get_from_register;
    // those are the signals which are always correct
    // e.g.: they keep the value in the stall case
    logic [63:0]              vaddr;
    logic [63:0]              data;
    logic [7:0]               be;
    fu_op                     operator;
    logic [TRANS_ID_BITS-1:0] trans_id;

    // registered address in case of a necessary stall
    logic [63:0]              vaddr_q;
    logic [63:0]              data_q;
    fu_op                     operator_q;
    logic [TRANS_ID_BITS-1:0] trans_id_q;
    // stall signal e.g.: do not update registers from above
    logic stall;

     // for ld/st address checker
    logic [63:0]             st_buffer_paddr;   // physical address for store
    logic [63:0]             st_buffer_data;  // store buffer data out
    logic [7:0]              st_buffer_be;
    logic                    st_buffer_valid;
    // store buffer control signals
    logic        st_ready;
    logic        st_valid;
    // from MMU
    logic translation_req, translation_valid;
    logic [63:0]  paddr_o;

    // ------------------------------
    // Address Generation Unit (AGU)
    // ------------------------------
    assign vaddr_i = imm_i + operand_a_i;

    // ---------------
    // Memory Arbiter
    // ---------------
    logic [2:0][63:0] address_i;
    logic [2:0][63:0] data_wdata_i;
    logic [2:0] data_req_i;
    logic [2:0] data_we_i;
    logic [2:0][7:0] data_be_i;
    logic [2:0] data_gnt_o;
    logic [2:0] data_rvalid_o;
    logic [2:0][63:0] data_rdata_o;

    // port 0 PTW, port 1 loads, port 2 stores
    mem_arbiter mem_arbiter_i (
        // to D$
        .address_o     ( data_if_address_o     ),
        .data_wdata_o  ( data_if_data_wdata_o  ),
        .data_req_o    ( data_if_data_req_o    ),
        .data_we_o     ( data_if_data_we_o     ),
        .data_be_o     ( data_if_data_be_o     ),
        .data_gnt_i    ( data_if_data_gnt_i    ),
        .data_rvalid_i ( data_if_data_rvalid_i ),
        .data_rdata_i  ( data_if_data_rdata_i  ),

        // from PTW, Load logic and store queue
        .address_i     ( address_i             ),
        .data_wdata_i  ( data_wdata_i          ),
        .data_req_i    ( data_req_i            ),
        .data_we_i     ( data_we_i             ),
        .data_be_i     ( data_be_i             ),
        .data_gnt_o    ( data_gnt_o            ),
        .data_rvalid_o ( data_rvalid_o         ),
        .data_rdata_o  ( data_rdata_o          ),
        .flush_ready_o (                       ), // TODO: connect, wait for flush to be valid
        .*
    );

    // connect the load logic to the memory arbiter
    assign address_i [1]       = paddr_o;
    // this is a read only interface
    assign data_we_i    [1]    = 1'b0;
    assign data_wdata_i [1]    = 64'b0;
    assign data_be_i    [1]    = be;
    logic [63:0] rdata;
    // data coming from arbiter interface 1
    assign rdata = data_rdata_o[1];
    // -------------------
    // MMU e.g.: TLBs/PTW
    // -------------------
    mmu #(
        .INSTR_TLB_ENTRIES      ( 16                ),
        .DATA_TLB_ENTRIES       ( 16                ),
        .ASID_WIDTH             ( ASID_WIDTH        )
    ) mmu_i (
        .lsu_req_i              ( translation_req   ),
        .lsu_vaddr_i            ( vaddr             ),
        .lsu_valid_o            ( translation_valid ),
        .lsu_paddr_o            ( paddr_o           ),
        // connecting PTW to D$ IF (aka mem arbiter
        .data_if_address_o      ( address_i     [0] ),
        .data_if_data_wdata_o   ( data_wdata_i  [0] ),
        .data_if_data_req_o     ( data_req_i    [0] ),
        .data_if_data_we_o      ( data_we_i     [0] ),
        .data_if_data_be_o      ( data_be_i     [0] ),
        .data_if_data_gnt_i     ( data_gnt_o    [0] ),
        .data_if_data_rvalid_i  ( data_rvalid_o [0] ),
        .data_if_data_rdata_i   ( data_rdata_o  [0] ),
        .*
    );

    // ------------------
    // Address Checker
    // ------------------
    logic page_offset_match;
    // checks if the requested load is in the store buffer
    // page offsets are virtually and physically the same
    always_comb begin : address_checker
        page_offset_match = 1'b0;
        // check if the LSBs are identical and the entry is valid
        if ((paddr_o[11:3] == st_buffer_paddr[11:3]) & st_buffer_valid) begin
            // TODO: implement propperly, this is overly pessimistic
            page_offset_match = 1'b1;
        end
    end

    // ------------------
    // LSU Control
    // ------------------
    // is the operation a load or store or nothing of relevance for the LSU
    enum logic [1:0] { NONE, LD_OP, ST_OP } op;

    always_comb begin : lsu_control
        // default assignment
        NS = CS;
        lsu_trans_id_o    = trans_id;
        lsu_ready_o       = 1'b1;
        // is the store valid e.g.: can we put it in the store buffer
        st_valid          = 1'b0;
        // as a default we are not requesting on the read interface
        data_req_i[1]     = 1'b0;
        // request the address translation
        translation_req   = 1'b0;
        // as a default we don't stall
        stall             = 1'b0;
        // as a default we won't take the operands from the internal
        // registers
        get_from_register = 1'b0;
        // LSU result is valid
        // we need to give the valid result even to stores
        lsu_valid_o       = 1'b0;
        unique case (CS)
            default:;
        endcase
    end

    // determine whether this is a load or store
    always_comb begin : which_op
        unique case (operator_i)
            // all loads go here
            LD, LW, LWU, LH, LHU, LB, LBU:  op = LD_OP;
            // all stores go here
            SD, SW, SH, SB:                 op = ST_OP;
            // not relevant for the lsu
            default:                        op = NONE;
        endcase
    end

    // ---------------
    // Store Queue
    // ---------------
    store_queue store_queue_i (
        // store queue write port
        .valid_i       ( st_valid            ),
        .paddr_i       ( paddr_o             ),
        .data_i        ( data                ),
        .be_i          ( be                  ),
        // store buffer in
        .paddr_o       ( st_buffer_paddr     ),
        .data_o        ( st_buffer_data      ),
        .valid_o       ( st_buffer_valid     ),
        .be_o          ( st_buffer_be        ),
        .ready_o       ( st_ready            ),

        .address_o     ( address_i    [2]    ),
        .data_wdata_o  ( data_wdata_i [2]    ),
        .data_req_o    ( data_req_i   [2]    ),
        .data_we_o     ( data_we_i    [2]    ),
        .data_be_o     ( data_be_i    [2]    ),
        .data_gnt_i    ( data_gnt_o   [2]    ),
        .data_rvalid_i ( data_rvalid_o[2]    ),
        .*
    );

    // ---------------
    // Byte Enable - TODO: Find a more beautiful way to accomplish this functionality
    // ---------------
    always_comb begin : byte_enable
        be = 8'b0;
        // we can generate the byte enable from the virtual address since the last
        // 12 bit are the same anyway
        // and we can always generate the byte enable from the address at hand
        case (operator)
            LD, SD: // double word
                    be = 8'b1111_1111;
            LW, LWU, SW: // word
                case (vaddr[2:0])
                    3'b000: be = 8'b0000_1111;
                    3'b001: be = 8'b0001_1110;
                    3'b010: be = 8'b0011_1100;
                    3'b011: be = 8'b0111_1000;
                    3'b100: be = 8'b1111_0000;
                    default:;
                endcase
            LH, LHU, SH: // half word
                case (vaddr[2:0])
                    3'b000: be = 8'b0000_0011;
                    3'b001: be = 8'b0000_0110;
                    3'b010: be = 8'b0000_1100;
                    3'b011: be = 8'b0001_1000;
                    3'b100: be = 8'b0011_0000;
                    3'b101: be = 8'b0110_0000;
                    3'b110: be = 8'b1100_0000;
                    default:;
                endcase
            LB, LBU, SB: // byte
                case (vaddr[2:0])
                    3'b000: be = 8'b0000_0001;
                    3'b001: be = 8'b0000_0010;
                    3'b010: be = 8'b0000_0100;
                    3'b011: be = 8'b0000_1000;
                    3'b100: be = 8'b0001_0000;
                    3'b101: be = 8'b0010_0000;
                    3'b110: be = 8'b0100_0000;
                    3'b111: be = 8'b1000_0000;
                endcase
            default:
                be = 8'b0;
        endcase
    end

    // ---------------
    // Sign Extend
    // ---------------

    logic [63:0] rdata_d_ext; // sign extension for double words, actually only misaligned assembly
    logic [63:0] rdata_w_ext; // sign extension for words
    logic [63:0] rdata_h_ext; // sign extension for half words
    logic [63:0] rdata_b_ext; // sign extension for bytes

    // double words
    always_comb begin : sign_extend_double_word
        rdata_d_ext = rdata[63:0];
    end

      // sign extension for words
    always_comb begin : sign_extend_word
        case (vaddr[2:0])
            default: rdata_w_ext = (operator == LW) ? {{32{rdata[31]}}, rdata[31:0]}  : {32'h0, rdata[31:0]};
            3'b001:  rdata_w_ext = (operator == LW) ? {{32{rdata[39]}}, rdata[39:8]}  : {32'h0, rdata[39:8]};
            3'b010:  rdata_w_ext = (operator == LW) ? {{32{rdata[47]}}, rdata[47:16]} : {32'h0, rdata[47:16]};
            3'b011:  rdata_w_ext = (operator == LW) ? {{32{rdata[55]}}, rdata[55:24]} : {32'h0, rdata[55:24]};
            3'b100:  rdata_w_ext = (operator == LW) ? {{32{rdata[63]}}, rdata[63:32]} : {32'h0, rdata[63:32]};
        endcase
    end

    // sign extension for half words
    always_comb begin : sign_extend_half_word
        case (vaddr[2:0])
            default: rdata_h_ext = (operator == LH) ? {{48{rdata[15]}}, rdata[15:0]}  : {48'h0, rdata[15:0]};
            3'b001:  rdata_h_ext = (operator == LH) ? {{48{rdata[23]}}, rdata[23:8]}  : {48'h0, rdata[23:8]};
            3'b010:  rdata_h_ext = (operator == LH) ? {{48{rdata[31]}}, rdata[31:16]} : {48'h0, rdata[31:16]};
            3'b011:  rdata_h_ext = (operator == LH) ? {{48{rdata[39]}}, rdata[39:24]} : {48'h0, rdata[39:24]};
            3'b100:  rdata_h_ext = (operator == LH) ? {{48{rdata[47]}}, rdata[47:32]} : {48'h0, rdata[47:32]};
            3'b101:  rdata_h_ext = (operator == LH) ? {{48{rdata[55]}}, rdata[55:40]} : {48'h0, rdata[55:40]};
            3'b110:  rdata_h_ext = (operator == LH) ? {{48{rdata[63]}}, rdata[63:48]} : {48'h0, rdata[63:48]};
        endcase
    end

    always_comb begin : sign_extend_byte
        case (vaddr[2:0])
            default: rdata_b_ext = (operator == LB) ? {{56{rdata[7]}},  rdata[7:0]}   : {56'h0, rdata[7:0]};
            3'b001:  rdata_b_ext = (operator == LB) ? {{56{rdata[15]}}, rdata[15:8]}  : {56'h0, rdata[15:8]};
            3'b010:  rdata_b_ext = (operator == LB) ? {{56{rdata[23]}}, rdata[23:16]} : {56'h0, rdata[23:16]};
            3'b011:  rdata_b_ext = (operator == LB) ? {{56{rdata[31]}}, rdata[31:24]} : {56'h0, rdata[31:24]};
            3'b100:  rdata_b_ext = (operator == LB) ? {{56{rdata[39]}}, rdata[39:32]} : {56'h0, rdata[39:32]};
            3'b101:  rdata_b_ext = (operator == LB) ? {{56{rdata[47]}}, rdata[47:40]} : {56'h0, rdata[47:40]};
            3'b110:  rdata_b_ext = (operator == LB) ? {{56{rdata[55]}}, rdata[55:48]} : {56'h0, rdata[55:48]};
            3'b111:  rdata_b_ext = (operator == LB) ? {{56{rdata[63]}}, rdata[63:56]} : {56'h0, rdata[63:56]};
        endcase
    end

    always_comb begin
        case (operator)
            LW, LWU:       lsu_result_o = rdata_w_ext;
            LH, LHU:       lsu_result_o = rdata_h_ext;
            LB, LBU:       lsu_result_o = rdata_b_ext;
            default:       lsu_result_o = rdata_d_ext;
        endcase
    end

    // ------------------
    // Exception Control
    // ------------------
    // misaligned detector
    // page fault, privilege exception
    // we can detect a misaligned exception immediately
    always_comb begin : data_misaligned_detection
        data_misaligned = 1'b0;

        if(lsu_valid_i) begin
          case (operator_i)
            LD, SD: begin // double word
              if(vaddr_i[2:0] != 3'b000)
                data_misaligned = 1'b1;
            end

            LW, LWU, SW: begin // word
              if(vaddr_i[2] == 1'b1 && vaddr_i[2:0] != 3'b100)
                data_misaligned = 1'b1;
            end

            LH, LHU, SH: begin // half word
              if(vaddr_i[2:0] == 3'b111)
                data_misaligned = 1'b1;
            end  // byte -> is always aligned
            default:;
          endcase
        end
    end

    always_comb begin : exception_control
        lsu_exception_o = {
            64'b0,
            64'b0,
            1'b0
        };
        if (data_misaligned) begin
            if (op == LD_OP) begin
                lsu_exception_o = {
                    64'b0,
                    LD_ADDR_MISALIGNED,
                    1'b1
                };
            end else if (op == ST_OP) begin
                lsu_exception_o = {
                    64'b0,
                    ST_ADDR_MISALIGNED,
                    1'b1
                };
            end
        end
    end

    // this process selects the input based on the current state of the LSU
    // it can either be feedthrough from the issue stage or from the internal register
    always_comb begin : input_select
        // if we are stalling use the values we saved
        if (lsu_ready_o) begin
            vaddr    = vaddr_q;
            data     = data_q;
            operator = operator_q;
            trans_id = trans_id_q;
        end else begin // otherwise pass them directly through
            vaddr    = vaddr_i;
            data     = operand_b_i;
            operator = operator_i;
            trans_id = trans_id_i;
        end
    end

    // registers
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            vaddr_q      <= 64'b0;
            data_q       <= 64'b0;
            operator_q   <= ADD;
            trans_id_q   <= '{default: 0};
            CS           <= IDLE;
        end else begin
            CS <= NS;
            if (lsu_ready_o) begin
                vaddr_q    <= vaddr_i;
                data_q     <= operand_b_i;
                operator_q <= operator_i;
                trans_id_q <= trans_id_i;
            end
        end
    end

    // ------------
    // Assertions
    // ------------

    // // make sure there is no new request when the old one is not yet completely done
    // // i.e. it should not be possible to get a grant without an rvalid for the
    // // last request
    `ifndef SYNTHESIS
    `ifndef VERILATOR
    // assert property (
    //   @(posedge clk) ((CS == WAIT_RVALID) && (data_gnt_i == 1'b1)) |-> (data_rvalid_i == 1'b1) )
    //   else begin $error("data grant without rvalid"); $stop(); end

    // // there should be no rvalid when we are in IDLE
    // assert property (
    //   @(posedge clk) (CS == IDLE) |-> (data_rvalid_i == 1'b0) )
    //   else begin $error("Received rvalid while in IDLE state"); $stop(); end

    // // assert that errors are only sent at the same time as grant or rvalid
    // assert property ( @(posedge clk) (data_err_i) |-> (data_gnt_i || data_rvalid_i) )
    //   else begin $error("Error without data grant or rvalid"); $stop(); end

    // assert that errors are only sent at the same time as grant or rvalid
    // assert that we only get a valid in if we said that we are ready
    // assert property ( @(posedge clk_i) lsu_valid_i |->  lsu_ready_o)
    //   else begin $error("[LSU] We got a valid but didn't say we were ready."); $stop(); end

    // // assert that the address does not contain X when request is sent
    // assert property ( @(posedge clk) (data_req_o) |-> (!$isunknown(data_addr_o)) )
    //   else begin $error("address contains X when request is set"); $stop(); end
    `endif
    `endif
endmodule