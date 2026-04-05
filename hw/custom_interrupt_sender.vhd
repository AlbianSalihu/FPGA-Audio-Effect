library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- customIRQSender: lightweight hardware mailbox for inter-processor notification.
-- CPU0 writes a 32-bit message (SDRAM base address) to reg 0, which immediately
-- raises the IRQ line. CPU1's ISR reads the address from reg 0, then writes to
-- reg 1 to acknowledge and lower the IRQ. No shared-memory polling required.
entity customIRQSender is
    port(
        clk : in std_logic;
        nReset : in std_logic;

        -- Avalon Slave interface
        address : in std_logic_vector(1 downto 0);
        write : in std_logic;
        read : in std_logic;
        writedata : in std_logic_vector(31 downto 0);
        readdata : out std_logic_vector(31 downto 0);

        -- IRQ
        IRQ : out std_logic
    );
end customIRQSender;

architecture comp of customIRQSender is
    -- Register map:
    --   address "00" (reg 0): RegMessage  — 32-bit payload (SDRAM base address)
    --   address "01" (reg 1): RegAckIRQ   — write to deassert IRQ and clear message
    signal iRegMessage : std_logic_vector(31 downto 0);
    signal iRegAckIRQ : std_logic;

begin
    -- Avalon Slave write
    process(clk, nReset)
    begin
        if nReset = '0' then
            IRQ <= '0';
            iRegMessage <= (others => '0');
        elsif rising_edge(clk) then
            if write = '1' then
                case address is
                    when "00" =>
                        IRQ <= '1';          -- raise IRQ immediately on message write
                        iRegAckIRQ <= '1';
                        iRegMessage <= writedata;
                    when "01" =>
                        IRQ <= '0';          -- lower IRQ on acknowledgement
                        iRegAckIRQ <= '0';
                        iRegMessage <= (others => '0');
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    -- Avalon Slave read
    process(clk)
    begin
        if rising_edge(clk) then
            readdata <= (others => '0');
            if read = '1' then
                case address is
                    when "00" => readdata <= iRegMessage;
                    when "01" => readdata(0) <= iRegAckIRQ;
                    when others => null;
                end case;
            end if;
        end if;
    end process;
end comp;
