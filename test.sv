`timescale 1ns/1ps

//----------------------------------
// (A) coord_storage (可多次收集)
//----------------------------------
module coord_storage (
    input  wire        clk,
    input  wire        rst,       // 高電平有效
    input  wire        restart,   // 額外的「重啟收集」訊號
    input  wire signed [9:0]  x_in,
    input  wire signed [9:0]  y_in,

    // fence 輸出: 6 組
    output reg  signed [9:0]  x_out [0:5],
    output reg  signed [9:0]  y_out [0:5],

    // target 輸出: 第 0 筆
    output reg  signed [9:0]  target_out_x,
    output reg  signed [9:0]  target_out_y,

    // 收集完成旗標
    output reg         ready
);

    // 暫存 7 筆: index=0 => target, 1..6 => fence
    reg signed[9:0] x_mem [0:6];
    reg signed[9:0] y_mem [0:6];

    reg [2:0] counter;    // 0..6
    reg       storing;

    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            storing <= 1;
            ready   <= 0;
            counter <= 0;
            target_out_x <= 0;
            target_out_y <= 0;
            for (i = 0; i < 6; i = i + 1) begin
                x_out[i] <= 0; 
                y_out[i] <= 0;
            end
            for (i = 0; i < 7; i = i + 1) begin
                x_mem[i] <= 0;
                y_mem[i] <= 0;
            end
        end
        else if (restart) begin
            // 重新開始收集新一組資料
            storing <= 1;
            ready   <= 0;
            counter <= 0;
            for (i = 0; i < 7; i = i + 1) begin
                x_mem[i] <= 0;
                y_mem[i] <= 0;
            end
        end
        else if (storing) begin
            // 每個 clock 接收一筆 (自動)
            x_mem[counter] <= x_in;
            y_mem[counter] <= y_in;
            $display($time,,"coord_storage capture: mem[%0d] <= (%0d,%0d)", 
                     counter, x_in, y_in);

            counter <= counter + 1;
            if (counter == 6) begin
                storing <= 0; // 收完 7 筆
            end
        end
        else begin
            // storing=0 → 複製到輸出 (只做一次)
            if (!ready) begin
                // 第 0 筆 -> target
                target_out_x <= x_mem[0];
                target_out_y <= y_mem[0];

                // fence => x_out[0..5], y_out[0..5]
                for (i = 1; i <= 6; i = i + 1) begin
                    x_out[i-1] <= x_mem[i];
                    y_out[i-1] <= y_mem[i];
                end

                ready <= 1;
                $display($time,,"coord_storage done, ready=1. target=(%0d,%0d)",
                         x_mem[0], y_mem[0]);
            end
        end
    end

endmodule


//----------------------------------
// (B) sort_fence_fsm (可重複啟動)
//----------------------------------
module sort_fence_fsm (
    input  wire             clk,
    input  wire             rst,      // 高電平有效
    input  wire             restart,  // 額外的「重啟FSM」訊號
    input  wire             start,    // 啟動排序 (由 coord_storage.ready 提供)

    // 輸入 6 組 (fence)
    input  signed [9:0]     in_x0, in_x1, in_x2, in_x3, in_x4, in_x5,
    input  signed [9:0]     in_y0, in_y1, in_y2, in_y3, in_y4, in_y5,

    // 排序完成 (單週期 valid)
    output reg              sorted_valid,

    // 排序後的 6 組 (fence)
    output reg signed [9:0] out_x0, out_x1, out_x2, out_x3, out_x4, out_x5,
    output reg signed [9:0] out_y0, out_y1, out_y2, out_y3, out_y4, out_y5
);

    // 狀態定義
    parameter IDLE        = 4'd0,
              LOAD        = 4'd1,
              INIT        = 4'd2,
              CROSS_SETUP = 4'd3,
              CROSS_WAIT  = 4'd4,
              CHECK_SWAP  = 4'd5,
              INCR_J      = 4'd6,
              INCR_I      = 4'd7,
              DONE        = 4'd8;

    reg [3:0] current_state, next_state;

    // 暫存 6 組 (x,y)
    reg signed [9:0] temp_x0, temp_x1, temp_x2, temp_x3, temp_x4, temp_x5;
    reg signed [9:0] temp_y0, temp_y1, temp_y2, temp_y3, temp_y4, temp_y5;

    // Bubble sort 計數器
    reg [2:0] i_ctr;
    reg [2:0] j_ctr;

    // Cross product 暫存
    reg signed [9:0] pivot_x, pivot_y;
    reg signed [9:0] a_x, a_y;
    reg signed [9:0] b_x, b_y;
    reg signed [20:0] cross_sign;

    // 只想在 DONE 狀態的第一拍把 sorted_valid 拉高一次
    reg done_reg;

    // 狀態暫存器
    always @(posedge clk or posedge rst) begin
        if (rst)
            current_state <= IDLE;
        else if (restart)
            current_state <= IDLE;  // 額外重啟
        else
            current_state <= next_state;
    end

    // 下一狀態邏輯
    always @(*) begin
        next_state = current_state;
        case (current_state)
            IDLE:       
                if (start)     
                    next_state = LOAD;

            LOAD:       
                next_state = INIT;

            INIT:       
                next_state = CROSS_SETUP;

            CROSS_SETUP:
                next_state = CROSS_WAIT;

            CROSS_WAIT: 
                next_state = CHECK_SWAP;

            CHECK_SWAP: 
                next_state = INCR_J;

            INCR_J:     
                if (j_ctr < 5 - i_ctr) 
                    next_state = CROSS_SETUP;
                else                  
                    next_state = INCR_I;

            INCR_I:     
                if (i_ctr < 4) 
                    next_state = CROSS_SETUP;
                else            
                    next_state = DONE;

            DONE:       
                next_state = DONE;

            default:
                next_state = IDLE;
        endcase
    end

    // 狀態動作 + 排序流程
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sorted_valid <= 1'b0;
            i_ctr <= 0;
            j_ctr <= 0;
            cross_sign <= 0;
            temp_x0 <= 0; temp_x1 <= 0; temp_x2 <= 0;
            temp_x3 <= 0; temp_x4 <= 0; temp_x5 <= 0;
            temp_y0 <= 0; temp_y1 <= 0; temp_y2 <= 0;
            temp_y3 <= 0; temp_y4 <= 0; temp_y5 <= 0;
            pivot_x <= 0; pivot_y <= 0;
            a_x <= 0; a_y <= 0;
            b_x <= 0; b_y <= 0;
            done_reg <= 0;
        end
        else if (restart) begin
            // 額外重啟
            sorted_valid <= 1'b0;
            i_ctr <= 0;
            j_ctr <= 0;
            cross_sign <= 0;
            temp_x0 <= 0; temp_x1 <= 0; temp_x2 <= 0;
            temp_x3 <= 0; temp_x4 <= 0; temp_x5 <= 0;
            temp_y0 <= 0; temp_y1 <= 0; temp_y2 <= 0;
            temp_y3 <= 0; temp_y4 <= 0; temp_y5 <= 0;
            pivot_x <= 0; pivot_y <= 0;
            a_x <= 0; a_y <= 0;
            b_x <= 0; b_y <= 0;
            done_reg <= 0;
        end
        else begin
            // 每個 clock 週期都先把 sorted_valid 拉回 0（除非剛完成）
            sorted_valid <= 1'b0;

            case (current_state)
                IDLE: begin
                    done_reg <= 0; // 准備進入新一輪
                end

                LOAD: begin
                    // 將輸入 6 點讀到暫存器
                    temp_x0 <= in_x0;  temp_x1 <= in_x1;  temp_x2 <= in_x2;
                    temp_x3 <= in_x3;  temp_x4 <= in_x4;  temp_x5 <= in_x5;
                    temp_y0 <= in_y0;  temp_y1 <= in_y1;  temp_y2 <= in_y2;
                    temp_y3 <= in_y3;  temp_y4 <= in_y4;  temp_y5 <= in_y5;
                end

                INIT: begin
                    pivot_x <= temp_x0;
                    pivot_y <= temp_y0;
                    i_ctr <= 0;
                    j_ctr <= 1;
                end

                CROSS_SETUP: begin
                    case (j_ctr)
                        1: begin
                            a_x <= temp_x1 - pivot_x;
                            a_y <= temp_y1 - pivot_y;
                            b_x <= temp_x2 - pivot_x;
                            b_y <= temp_y2 - pivot_y;
                        end
                        2: begin
                            a_x <= temp_x2 - pivot_x;
                            a_y <= temp_y2 - pivot_y;
                            b_x <= temp_x3 - pivot_x;
                            b_y <= temp_y3 - pivot_y;
                        end
                        3: begin
                            a_x <= temp_x3 - pivot_x;
                            a_y <= temp_y3 - pivot_y;
                            b_x <= temp_x4 - pivot_x;
                            b_y <= temp_y4 - pivot_y;
                        end
                        4: begin
                            a_x <= temp_x4 - pivot_x;
                            a_y <= temp_y4 - pivot_y;
                            b_x <= temp_x5 - pivot_x;
                            b_y <= temp_y5 - pivot_y;
                        end
                    endcase
                end

                CROSS_WAIT: begin
                    cross_sign <= (a_x * b_y) - (a_y * b_x);
                end

                CHECK_SWAP: begin
                    if (cross_sign < 0) begin
                        // 交換
                        case (j_ctr)
                            1: begin
                                reg signed [9:0] xx, yy;
                                xx = temp_x1; temp_x1 = temp_x2; temp_x2 = xx;
                                yy = temp_y1; temp_y1 = temp_y2; temp_y2 = yy;
                            end
                            2: begin
                                reg signed [9:0] xx, yy;
                                xx = temp_x2; temp_x2 = temp_x3; temp_x3 = xx;
                                yy = temp_y2; temp_y2 = temp_y3; temp_y3 = yy;
                            end
                            3: begin
                                reg signed [9:0] xx, yy;
                                xx = temp_x3; temp_x3 = temp_x4; temp_x4 = xx;
                                yy = temp_y3; temp_y3 = temp_y4; temp_y4 = yy;
                            end
                            4: begin
                                reg signed [9:0] xx, yy;
                                xx = temp_x4; temp_x4 = temp_x5; temp_x5 = xx;
                                yy = temp_y4; temp_y4 = temp_y5; temp_y5 = yy;
                            end
                        endcase
                    end
                end

                INCR_J: begin
                    if (j_ctr < 5 - i_ctr) begin
                        j_ctr <= j_ctr + 1;
                    end
                end

                INCR_I: begin
                    if (i_ctr < 4) begin
                        i_ctr <= i_ctr + 1;
                        j_ctr <= 1;
                    end
                end

                DONE: begin
                    if (!done_reg) begin
                        done_reg <= 1'b1;
                        sorted_valid <= 1'b1;  // 單週期
                        // 把排序結果輸出
                        out_x0 <= temp_x0;  out_y0 <= temp_y0;
                        out_x1 <= temp_x1;  out_y1 <= temp_y1;
                        out_x2 <= temp_x2;  out_y2 <= temp_y2;
                        out_x3 <= temp_x3;  out_y3 <= temp_y3;
                        out_x4 <= temp_x4;  out_y4 <= temp_y4;
                        out_x5 <= temp_x5;  out_y5 <= temp_y5;
                    end
                end
            endcase
        end
    end

endmodule


//----------------------------------
// (C) inside_checker
//----------------------------------
module inside_checker (
    input   wire        clk,
    input   wire        rst,          // 高電平有效
    input   wire        sorted_valid, // 單週期有效

    // 排序好的 6 筆座標
    input   wire signed [9:0]  sorted_x0, sorted_x1, sorted_x2,
                        sorted_x3, sorted_x4, sorted_x5,
    input   wire signed[9:0]  sorted_y0, sorted_y1, sorted_y2,
                        sorted_y3, sorted_y4, sorted_y5,

    // 目標座標
    input   wire signed [9:0]  target_out_x,
    input   wire signed [9:0]  target_out_y,

    // 輸出：在同一拍輸出 is_inside, valid=1
    output reg          is_inside,  // 1=在內部, 0=不在/在邊界
    output reg          valid       // 單週期脈波
);

    // 用於外積
    function signed [20:0] cross_2D(
        input signed [9:0] Ax,
        input signed [9:0] Ay,
        input signed [9:0] Bx,
        input signed [9:0] By
    );
        cross_2D = Ax * By - Ay * Bx;
    endfunction

    // 組合邏輯：計算所有外積，判斷是否全同號
    reg signed [20:0] c0, c1, c2, c3, c4, c5;
    reg               inside_flag_comb;

    always @(*) begin
        // 預設為 0
        c0 = 0; c1 = 0; c2 = 0; c3 = 0; c4 = 0; c5 = 0;
        inside_flag_comb = 1'b0;

        if (sorted_valid) begin
            c0 = cross_2D(
                $signed(target_out_x) - $signed(sorted_x0),
                $signed(target_out_y) - $signed(sorted_y0),
                $signed(sorted_x1)   - $signed(sorted_x0),
                $signed(sorted_y1)   - $signed(sorted_y0)
            );
            c1 = cross_2D(
                $signed(target_out_x) - $signed(sorted_x1),
                $signed(target_out_y) - $signed(sorted_y1),
                $signed(sorted_x2)   - $signed(sorted_x1),
                $signed(sorted_y2)   - $signed(sorted_y1)
            );
            c2 = cross_2D(
                $signed(target_out_x) - $signed(sorted_x2),
                $signed(target_out_y) - $signed(sorted_y2),
                $signed(sorted_x3)   - $signed(sorted_x2),
                $signed(sorted_y3)   - $signed(sorted_y2)
            );
            c3 = cross_2D(
                $signed(target_out_x) - $signed(sorted_x3),
                $signed(target_out_y) - $signed(sorted_y3),
                $signed(sorted_x4)   - $signed(sorted_x3),
                $signed(sorted_y4)   - $signed(sorted_y3)
            );
            c4 = cross_2D(
                $signed(target_out_x) - $signed(sorted_x4),
                $signed(target_out_y) - $signed(sorted_y4),
                $signed(sorted_x5)   - $signed(sorted_x4),
                $signed(sorted_y5)   - $signed(sorted_y4)
            );
            c5 = cross_2D(
                $signed(target_out_x) - $signed(sorted_x5),
                $signed(target_out_y) - $signed(sorted_y5),
                $signed(sorted_x0)   - $signed(sorted_x5),
                $signed(sorted_y0)   - $signed(sorted_y5)
            );

            // 簡單判斷：若 c0..c5 都 > 0 => inside=1
            inside_flag_comb = ((c0>0 && c1>0 && c2>0 && c3>0 && c4>0 && c5>0)||(c0<0 && c1<0 && c2<0 && c3<0 && c4<0 && c5<0));
        end
    end

    // 同步區塊：在 sorted_valid=1 的同一拍，就輸出結果 + valid=1
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            is_inside <= 1'b0;
            valid     <= 1'b0;
        end
        else begin
            valid <= 1'b0; // 預設

            if (sorted_valid) begin
                is_inside <= inside_flag_comb;
                valid     <= 1'b1;
                $display($time,,"inside_checker => is_inside=%b (one-cycle valid=1)",
                         inside_flag_comb);
            end
        end
    end

endmodule


//----------------------------------
// (D) 頂層: fence_system (多次可重啟)
//----------------------------------
module fence_system (
    input  wire        clk,
    input  wire        rst,     // 高電平有效
    input  wire signed [9:0]  x_in,
    input  wire signed [9:0]  y_in,

    output wire        is_inside,
    output wire        inside_valid
);

    // ---------- 中間連線 ----------
    // coord_storage -> sort_fence_fsm
    wire        storage_ready;   
    wire signed [9:0]  fence_x [0:5];
    wire signed [9:0]  fence_y [0:5];
    wire signed [9:0]  target_x;
    wire signed [9:0]  target_y;

    // sort_fence_fsm -> inside_checker
    wire signed [9:0] srt_x0, srt_x1, srt_x2, srt_x3, srt_x4, srt_x5;
    wire signed [9:0] srt_y0, srt_y1, srt_y2, srt_y3, srt_y4, srt_y5;
    wire        sorted_valid;

    // (1) 額外產生一條 「多次重啟」訊號 do_restart
    //     - 只要偵測到 inside_valid=1，那麼在「下一拍」對子模組送一次 restart=1
    reg do_restart, inside_valid_dly;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            do_restart      <= 1'b0;
            inside_valid_dly<= 1'b0;
        end
        else begin
            // 先記錄上一拍的 inside_valid
            inside_valid_dly <= inside_valid;
            // 預設不重啟
            do_restart <= 1'b0;
            // 若本拍(或上一拍) inside_valid=1 -> 下一拍 do_restart=1
            // 這裡做「偵測上拍 inside_valid=1」的方式
            if (inside_valid_dly == 1'b1)
                do_restart <= 1'b1;  // 單拍脈波
        end
    end

    // (2) coord_storage
    coord_storage u_coord_storage (
        .clk          (clk),
        .rst          (rst),
        .restart      (do_restart),
        .x_in         (x_in),
        .y_in         (y_in),
        .x_out        (fence_x),
        .y_out        (fence_y),
        .target_out_x (target_x),
        .target_out_y (target_y),
        .ready        (storage_ready)
    );

    // (3) sort_fence_fsm
    sort_fence_fsm u_sort_fence_fsm (
        .clk          (clk),
        .rst          (rst),
        .restart      (do_restart),  // 多次重啟
        .start        (storage_ready),

        .in_x0        (fence_x[0]),
        .in_x1        (fence_x[1]),
        .in_x2        (fence_x[2]),
        .in_x3        (fence_x[3]),
        .in_x4        (fence_x[4]),
        .in_x5        (fence_x[5]),

        .in_y0        (fence_y[0]),
        .in_y1        (fence_y[1]),
        .in_y2        (fence_y[2]),
        .in_y3        (fence_y[3]),
        .in_y4        (fence_y[4]),
        .in_y5        (fence_y[5]),

        .sorted_valid (sorted_valid),

        .out_x0       (srt_x0),
        .out_x1       (srt_x1),
        .out_x2       (srt_x2),
        .out_x3       (srt_x3),
        .out_x4       (srt_x4),
        .out_x5       (srt_x5),

        .out_y0       (srt_y0),
        .out_y1       (srt_y1),
        .out_y2       (srt_y2),
        .out_y3       (srt_y3),
        .out_y4       (srt_y4),
        .out_y5       (srt_y5)
    );

    // (4) inside_checker
    inside_checker u_inside_checker (
        .clk           (clk),
        .rst           (rst),
        .sorted_valid  (sorted_valid),
        .sorted_x0     (srt_x0),
        .sorted_x1     (srt_x1),
        .sorted_x2     (srt_x2),
        .sorted_x3     (srt_x3),
        .sorted_x4     (srt_x4),
        .sorted_x5     (srt_x5),
        .sorted_y0     (srt_y0),
        .sorted_y1     (srt_y1),
        .sorted_y2     (srt_y2),
        .sorted_y3     (srt_y3),
        .sorted_y4     (srt_y4),
        .sorted_y5     (srt_y5),
        .target_out_x  (target_x),
        .target_out_y  (target_y),
        .is_inside     (is_inside),
        .valid         (inside_valid)
    );

endmodule

