// Copyright 2022, 2023 Commissariat a l'Energie Atomique et aux Energies Alternatives (CEA)
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Author: Cesar Fuguet
// Date: December, 2022
// Description: Functional Unit for the forwarding of Cache Management Operations (CMOs)
//              to L1 caches
//
module cmo_fu import ariane_pkg::*; (
//  Ports
//  {{{
    input  logic                              clk_i,
    input  logic                              rst_ni,
    input  fu_data_t                          fu_data_i,
    //from issue
    input  logic                              cmo_valid_i,
    output logic                              cmo_ready_o,
    //to writeback
    output logic [TRANS_ID_BITS-1:0]          cmo_trans_id_o,
    output exception_t                        cmo_exception_o,
    output riscv::xlen_t                      cmo_result_o,
    output logic                              cmo_valid_o,
    //to L1I$
    output ariane_pkg::cmo_req_t              cmo_ic_req_o,
    input  ariane_pkg::cmo_resp_t             cmo_ic_resp_i,
    //to L1D$
    output ariane_pkg::cmo_req_t              cmo_dc_req_o,
    input  ariane_pkg::cmo_resp_t             cmo_dc_resp_i
//  }}}
);

    //  Constant and types definitions
    //  {{{
    typedef enum {
        CMO_IDLE,
        CMO_FORWARD
    } cmo_fsm_t;

    typedef struct packed {
        logic                     valid;
        logic [TRANS_ID_BITS-1:0] trans_id;
        riscv::xlen_t             address;
        fu_op                     operator;
    } cmo_buf_t;

    function automatic cmo_t cmo_fu_op_to_cmo_op(fu_op operator);
        case (operator)
            CMO_CLEAN:      return CMO_CLEAN;
            CMO_FLUSH:      return CMO_FLUSH;
            CMO_INVAL:      return CMO_INVAL;
            CMO_ZERO:       return CMO_ZERO;
            CMO_PREFETCH_I: return CMO_PREFETCH_I;
            CMO_PREFETCH_R: return CMO_PREFETCH_R;
            CMO_PREFETCH_W: return CMO_PREFETCH_W;
            default:           return CMO_NONE;
        endcase
    endfunction

    function automatic logic cmo_is_dc(fu_op operator);
        case (operator)
            CMO_CLEAN,
            CMO_FLUSH,
            CMO_INVAL,
            CMO_ZERO,
            CMO_PREFETCH_R,
            CMO_PREFETCH_W: return 1'b1;
            CMO_PREFETCH_I: return 1'b0;
            default:           return 1'b0;
        endcase
    endfunction
    //  }}}

    //  Internal signals and registers definitions
    //  {{{
    cmo_fsm_t cmo_fsm_q, cmo_fsm_d;
    cmo_buf_t cmo_buf_q, cmo_buf_d;
    logic is_cmo_ic_resp;
    //  }}}

    //  CMO FSM combinational function
    //  {{{
    always_comb
    begin
        cmo_fsm_d   = cmo_fsm_q;
        cmo_buf_d   = cmo_buf_q;
        cmo_ready_o = 1'b0;
        case (cmo_fsm_q)
            CMO_IDLE: begin
                cmo_ready_o = ~cmo_valid_i;
                if (cmo_valid_i) begin
                    cmo_buf_d.valid = 1'b1;
                    cmo_buf_d.trans_id = fu_data_i.trans_id;
                    cmo_buf_d.address = fu_data_i.operand_a;
                    cmo_buf_d.operator = fu_data_i.operator;
                    cmo_fsm_d = CMO_FORWARD;
                end
            end
            CMO_FORWARD: begin
                automatic bit req_accept = (cmo_ic_req_o.req & cmo_ic_resp_i.req_ready) |
                                           (cmo_dc_req_o.req & cmo_dc_resp_i.req_ready);
                if (req_accept) begin
                    cmo_buf_d.valid = 1'b0;
                    cmo_ready_o = 1'b1;
                    cmo_fsm_d = CMO_IDLE;
                end
            end
        endcase
    end
    //  }}}

    //  CMO FSM set state function
    //  {{{
    always_ff @(posedge clk_i or negedge rst_ni)
    begin
        if (!rst_ni) begin
            cmo_fsm_q <= CMO_IDLE;
            cmo_buf_q <= '0;
        end else begin
            cmo_fsm_q <= cmo_fsm_d;
            cmo_buf_q <= cmo_buf_d;
        end
    end
    //  }}}

    //  CMO FSM request outputs to cache subsystem
    //  {{{
    assign cmo_dc_req_o.req      = cmo_buf_q.valid & cmo_is_dc(cmo_buf_q.operator),
           cmo_dc_req_o.trans_id = cmo_buf_q.trans_id,
           cmo_dc_req_o.address  = cmo_buf_q.address,
           cmo_dc_req_o.cmo_op   = cmo_fu_op_to_cmo_op(cmo_buf_q.operator);

    assign cmo_ic_req_o.req      = cmo_buf_q.valid & ~cmo_is_dc(cmo_buf_q.operator),
           cmo_ic_req_o.trans_id = cmo_buf_q.trans_id,
           cmo_ic_req_o.address  = cmo_buf_q.address,
           cmo_ic_req_o.cmo_op   = cmo_fu_op_to_cmo_op(cmo_buf_q.operator);
    //  }}}

    //  CMO FSM response inputs from cache subsystem
    //  {{{
    assign is_cmo_ic_resp        = 1'b0; // FIXME
    assign cmo_valid_o           = is_cmo_ic_resp ? cmo_ic_resp_i.ack      : cmo_dc_resp_i.ack,
           cmo_trans_id_o        = is_cmo_ic_resp ? cmo_ic_resp_i.trans_id : cmo_dc_resp_i.trans_id,
           cmo_result_o          = '0,
           cmo_exception_o.cause = '0,
           cmo_exception_o.valid = '0,
           cmo_exception_o.tval  = '0;
    //  }}}

endmodule