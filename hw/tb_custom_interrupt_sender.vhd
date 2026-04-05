library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_custom_interrupt_sender is
end tb_custom_interrupt_sender;

architecture test_interrupt_sender of tb_custom_interrupt_sender is

    constant CLK_PERIOD  : time := 20 ns;
    constant TESTING_TIME : time := 300 ns;

    signal sim_finished : boolean := false;

    -- DUT ports
    signal clk      : std_logic;
    signal nReset   : std_logic;

    signal address   : std_logic_vector(1 downto 0);
    signal write     : std_logic;
    signal read      : std_logic;
    signal writedata : std_logic_vector(31 downto 0);
    signal readdata  : std_logic_vector(31 downto 0);

    signal IRQ : std_logic;

begin
    -- Instantiate DUT
    dut : entity work.customIRQSender
    port map(
        clk       => clk,
        nReset    => nReset,
        address   => address,
        write     => write,
        read      => read,
        writedata => writedata,
        readdata  => readdata,
        IRQ       => IRQ
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

    -- Drive one Avalon Slave transaction.
    -- Arguments: address, write, writedata, read
    procedure check_custom_IRQSender(
                constant simavs_Add    : in natural;
                constant simavs_Wr     : in natural;
                constant simavs_WrData : in natural;
                constant simavs_Rd     : in natural) is
    begin
        wait until rising_edge(clk);
        address   <= std_logic_vector(to_unsigned(simavs_Add,    address'length));
        write     <= '1' when simavs_Wr /= 0 else '0';
        writedata <= std_logic_vector(to_unsigned(simavs_WrData, writedata'length));
        read      <= '1' when simavs_Rd /= 0 else '0';
    end procedure check_custom_IRQSender;

    begin
        -- Default stimulus
        address   <= (others => '0');
        writedata <= (others => '0');
        nReset    <= '1';
        write     <= '0';
        read      <= '0';

        wait for CLK_PERIOD;
        async_reset;

        -- Send a message (write 1 to reg 0): should raise IRQ
        check_custom_IRQSender(0, 0, 0, 0);   -- idle
        check_custom_IRQSender(0, 1, 1, 0);   -- write message = 1 → IRQ raised
        check_custom_IRQSender(0, 0, 0, 0);   -- idle
        -- Acknowledge (write to reg 1): should lower IRQ
        check_custom_IRQSender(1, 1, 1, 0);   -- write AckIRQ → IRQ lowered
        check_custom_IRQSender(0, 0, 0, 0);   -- idle
        -- Read back message register
        check_custom_IRQSender(0, 0, 0, 1);   -- read reg 0 (RegMessage, now cleared)
        check_custom_IRQSender(0, 0, 0, 0);   -- idle

        wait for TESTING_TIME;
        sim_finished <= true;
        wait;

    end process simulation;

end architecture test_interrupt_sender;
