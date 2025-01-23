//===============================================
// tb_fence_system.v
//===============================================
`timescale 1ns/1ps

module tb_fence_system;
    reg  clk, rst;
    reg  [9:0] x_in, y_in;
    wire       is_inside, inside_valid;

    // 實例化頂層 (多次可重啟)
    fence_system u_fence_system (
        .clk         (clk),
        .rst         (rst),
        .x_in        (x_in),
        .y_in        (y_in),
        .is_inside   (is_inside),
        .inside_valid(inside_valid)
    );

    // 產生時脈 (10ns週期)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    initial begin
        $dumpfile("top.vcd");  // 或 wave.fst
        $dumpvars(0, tb_fence_system);
    end
    // 測試流程
    initial begin
        // 上電，先 reset
        #5
        rst = 1;
        x_in = 0;
        y_in = 0;
        #15;  
        rst = 0;  // 解除 reset
    end
     
    initial begin
    #15
    // 【Test1】目標在內部
    $display("\n[TB] ==== Start Test1 (7 coords) ====");
    send_coord(3,3);   // target
    send_coord(7,0);   // fence point 1
    send_coord(6,2);   // fence point 2
    send_coord(10,14);   // fence point 3
    send_coord(16,28);   // fence point 4
    send_coord(3,-6);   // fence point 5
    send_coord(-8,3);  // fence point 6
    wait_valid_and_print("Test1");

    // 【Test2】目標在外部
    $display("\n[TB] ==== Start Test2 (7 coords) ====");
    send_coord(3,3); // target
    send_coord(0,0);   // fence point 1
    send_coord(6,0);   // fence point 2
    send_coord(8,4);   // fence point 3
    send_coord(6,8);   // fence point 4
    send_coord(2,6);   // fence point 5
    send_coord(-1,3);  // fence point 6
    wait_valid_and_print("Test2");
    rst = 1;

    $finish;
    end

    // === 測試用 task：一次送 1 組 (x_in,y_in) ===
    task send_coord(input [9:0] xx, input [9:0] yy);
    begin
        @(posedge clk);
        x_in <= xx;
        y_in <= yy;
    end
    endtask

    // === 等到 valid=1，印出結果，然後再等 1 拍 ===
    task wait_valid_and_print(input [127:0] msg);
    begin
        // 先等待 valid=1
        while (!inside_valid) @(posedge clk);
        
        // 再多等1拍 => 才進入下一組資料的輸入階段
            
        @(posedge clk);
    end
    endtask

endmodule

