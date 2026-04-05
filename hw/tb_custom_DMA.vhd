library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_accelarator is
end tb_accelarator;

-- Basic testbench for custom_DMA.
-- Exercises the Avalon Slave register interface (source address, destination address,
-- transfer length, byte width) and the Start/AckIRQ control flow.
-- Memory responses are stubbed: avm_WaitRequest is held low and avm_RdData is
-- set to a fixed value, so the FSM runs freely without a memory model.
architecture test_accelarator of tb_accelarator is

    constant CLK_PERIOD  : time := 20 ns;
    constant TESTING_TIME : time := 300 ns;

    signal sim_finished : boolean := false;

    -- DUT ports
    signal clk            : std_logic;
    signal nReset         : std_logic;

    -- Slave part
    signal avs_Add        : std_logic_vector(3 downto 0);
    signal avs_CS         : std_logic;
    signal avs_Wr         : std_logic;
    signal avs_Rd         : std_logic;
    signal avs_WrData     : std_logic_vector(31 downto 0);
    signal avs_RdData     : std_logic_vector(31 downto 0);

    -- Master part
    signal avm_Add        : std_logic_vector(31 downto 0);
    signal avm_BE         : std_logic_vector(3 downto 0);
    signal avm_Wr         : std_logic;
    signal avm_Rd         : std_logic;
    signal avm_WrData     : std_logic_vector(31 downto 0);
    signal avm_RdData     : std_logic_vector(31 downto 0);
    signal avm_WaitRequest : std_logic;

    -- IRQ
    signal IRQ : std_logic;

begin
    -- Instantiate DUT
    dut : entity work.custom_DMA
    port map(
        clk            => clk,
        nReset         => nReset,
        avs_Add        => avs_Add,
        avs_CS         => avs_CS,
        avs_Wr         => avs_Wr,
        avs_Rd         => avs_Rd,
        avs_WrData     => avs_WrData,
        avs_RdData     => avs_RdData,
        avm_Add        => avm_Add,
        avm_BE         => avm_BE,
        avm_Wr         => avm_Wr,
        avm_Rd         => avm_Rd,
        avm_WrData     => avm_WrData,
        avm_RdData     => avm_RdData,
        avm_WaitRequest => avm_WaitRequest,
        IRQ            => IRQ
    );

    -- Clock generation
    clk_generation : process
    begin
        if not sim_finished then
            clk <= '1';
            wait for CLK_PERIOD / 2;
            clk <= '0';
            wait for CLK_PERIOD / 2;
        else
            wait;
        end if;
    end process clk_generation;

    -- Stimulus
    simulation : process

    procedure async_reset is
    begin
        wait until rising_edge(clk);
        wait for CLK_PERIOD / 4;
        nReset <= '0';
        wait for CLK_PERIOD / 2;
        nReset <= '1';
    end procedure async_reset;

    -- Drive one set of Avalon Slave inputs and stub the Master response.
    -- Arguments: avs_Add, avs_CS, avs_Wr, avs_WrData, avs_Rd, avm_WaitRequest, avm_RdData
    procedure check_custom_accelerator(
                constant simavs_Add        : in natural;
                constant simavs_CS         : in natural;
                constant simavs_Wr         : in natural;
                constant simavs_WrData     : in natural;
                constant simavs_Rd         : in natural;
                constant simavm_WaitRequest : in natural;
                constant simavm_RdData     : in natural) is
    begin
        wait until rising_edge(clk);
        avs_Add        <= std_logic_vector(to_unsigned(simavs_Add,    avs_Add'length));
        avs_CS         <= '1' when simavs_CS  /= 0 else '0';
        avs_Wr         <= '1' when simavs_Wr  /= 0 else '0';
        avs_WrData     <= std_logic_vector(to_unsigned(simavs_WrData,  avs_WrData'length));
        avs_Rd         <= '1' when simavs_Rd  /= 0 else '0';
        avm_WaitRequest <= '1' when simavm_WaitRequest /= 0 else '0';
        avm_RdData     <= std_logic_vector(to_unsigned(simavm_RdData,  avm_RdData'length));
    end procedure check_custom_accelerator;

    begin
        -- Default stimulus
        avs_Add        <= (others => '0');
        avs_WrData     <= (others => '0');
        nReset         <= '1';
        avs_Wr         <= '0';
        avs_Rd         <= '0';
        avs_CS         <= '0';
        avm_WaitRequest <= '0';
        avm_RdData     <= (others => '0');

        wait for CLK_PERIOD;
        async_reset;

        -- Program registers: src=0x00, dst=0x10, length=2, byte-width=2
        check_custom_accelerator(0, 0, 0, 0,  0, 0, 0);  -- idle cycle
        check_custom_accelerator(0, 1, 1, 0,  0, 0, 0);  -- reg 0: source address = 0x00
        check_custom_accelerator(1, 1, 1, 16, 0, 0, 0);  -- reg 1: destination address = 0x10
        check_custom_accelerator(2, 1, 1, 2,  0, 0, 0);  -- reg 2: length = 2 elements
        check_custom_accelerator(3, 1, 1, 2,  0, 0, 0);  -- reg 3: 2 bytes per element

        -- Start transfer, then read back the Start register
        check_custom_accelerator(4, 1, 1, 1, 0, 0, 0);   -- reg 4: Start = 1
        check_custom_accelerator(4, 1, 0, 0, 1, 0, 0);   -- read reg 4 (Start)
        check_custom_accelerator(0, 0, 0, 0, 0, 0, 0);   -- deassert all

        wait for TESTING_TIME;

        -- Acknowledge IRQ and restart
        check_custom_accelerator(7, 1, 1, 1, 0, 0, 0);   -- reg 7: AckIRQ
        check_custom_accelerator(4, 1, 1, 1, 0, 0, 0);   -- reg 4: Start = 1
        check_custom_accelerator(0, 0, 0, 0, 0, 0, 0);   -- deassert all

        wait for TESTING_TIME;
        sim_finished <= true;
        wait;

    end process simulation;

end architecture test_accelarator;
