library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity custom_DMA is
    port (
        clk: in std_logic;
        nReset: in std_logic;

        -- Slave part
        avs_Add: in std_logic_vector(3 downto 0);
        avs_CS: in std_logic;
        avs_Wr: in std_logic;
        avs_Rd: in std_logic;
        avs_WrData: in std_logic_vector(31 downto 0);
        avs_RdData: out std_logic_vector(31 downto 0);

        -- Master part
        avm_Add: out std_logic_vector(31 downto 0);
        avm_BE: out std_logic_vector(3 downto 0);
        avm_Wr: out std_logic;
        avm_Rd: out std_logic;
        avm_WrData: out std_logic_vector(31 downto 0);
        avm_RdData: in std_logic_vector(31 downto 0);
        avm_WaitRequest: in std_logic;

        -- IRQ
        IRQ : out std_logic
    );
end entity custom_DMA;

architecture comp of custom_DMA is

    -- Internal registers (Avalon Slave register map)
    signal RegAddStartSrc: std_logic_vector(31 downto 0);  -- reg 0: source start address
    signal RegAddStartDst: std_logic_vector(31 downto 0);  -- reg 1: destination start address
    signal RegLgtTable: std_logic_vector(31 downto 0);     -- reg 2: number of elements to transfer
    signal RegNbByte: std_logic_vector(3 downto 0);        -- reg 3: bytes per element
    signal Start: std_logic;                               -- reg 4: write 1 to begin transfer
    signal Finish: std_logic;                              -- reg 5: set by FSM on completion
    signal StopMaster: std_logic;                          -- reg 6: emergency stop
    signal AckIRQ: std_logic;                              -- reg 7: write to acknowledge IRQ

    signal WaitToStart: std_logic; -- holds start request until IRQ is cleared
    signal IRQStatus: std_logic;   -- internal IRQ state (drives IRQ output)

    signal DataRd: std_logic_vector(31 downto 0); -- read data buffer

    signal CntAddSrc: unsigned(31 downto 0); -- current source address
    signal CntAddDst: unsigned(31 downto 0); -- current destination address
    signal CntLgt: unsigned(31 downto 0);    -- remaining element count

    -- DMA transfer state machine
    type SM is (Idle, LdParam, RdAcc, WaitRd, WriteValue, WrEnd, EndTable);
    signal StateM: SM;

begin
    IRQ <= IRQStatus; -- expose internal IRQ state so we can read it back

-- Avalon Slave write: program the DMA configuration registers
AvalonSlaveWr:
process(clk, nReset)
begin
    if nReset = '0' then
        RegAddStartSrc <= (others => '0');
        RegAddStartDst <= (others => '0');
        RegLgtTable <= (others => '0');
        RegNbByte <= (others => '0');
        Start <= '0';
        StopMaster <= '0';
        AckIRQ <= '0';
    elsif rising_edge(clk) then
        Start <= '0';
        AckIRQ <= '0';
        if avs_CS = '1' and avs_Wr = '1' then
            case avs_Add is
                when "0000" => RegAddStartSrc <= avs_WrData;
                when "0001" => RegAddStartDst <= avs_WrData;
                when "0010" => RegLgtTable <= avs_WrData;
                when "0011" => RegNbByte <= avs_WrData(3 downto 0);
                when "0100" => Start <= avs_WrData(0);
                when "0101" => null;
                when "0110" => StopMaster <= avs_WrData(0);
                when "0111" => AckIRQ <= '1';
                when others => null;
            end case;
        end if;
    end if;
end process AvalonSlaveWr;

-- Avalon Slave read: one wait cycle (synchronous read)
AvalonSlaveRd:
process(clk)
begin
    if rising_edge(clk) then
        avs_RdData <= (others => '0');
        if avs_CS = '1' and avs_Rd = '1' then
            case avs_Add is
                when "0000" => avs_RdData <= RegAddStartSrc;
                when "0001" => avs_RdData <= RegAddStartDst;
                when "0010" => avs_RdData <= RegLgtTable;
                when "0011" => avs_RdData(3 downto 0) <= RegNbByte;
                when "0100" => avs_RdData(0) <= Start;
                when "0101" => avs_RdData(0) <= Finish;
                when "0110" => avs_RdData(0) <= StopMaster;
                when "0111" => avs_RdData(0) <= AckIRQ;
                when others => null;
            end case;
        end if;
    end if;
end process AvalonSlaveRd;

------------------------------------------------------------------------------------------
-- Avalon Master: 7-state FSM that performs the DMA transfer.
-- Reads each element from the source address and writes it to the destination address.
-- Handles Avalon back-pressure natively via WaitRequest.
AvalonMaster:
process(clk, nReset)
begin
    if nReset = '0' then
        Finish <= '0';
        WaitToStart <= '0';
        IRQStatus <= '0';
        CntAddSrc <= (others => '0');
        CntAddDst <= (others => '0');
        CntLgt <= (others => '0');
        StateM <= Idle;
    elsif rising_edge(clk) then
        if AckIRQ = '1' then
            IRQStatus <= '0'; -- deassert IRQ on acknowledgement
        end if;

        case StateM is
            when Idle => -- wait for Start command
                avm_Add <= (others => '0');
                avm_BE <= "0000";
                avm_Wr <= '0';
                avm_Rd <= '0';
                avm_WrData <= (others => '0');

                if Start = '1' or WaitToStart = '1' then
                    WaitToStart <= '1';
                    if IRQStatus = '0' then
                        StateM <= LdParam;
                        Finish <= '0';
                        WaitToStart <= '0';
                    end if;
                end if;

            when LdParam => -- latch configuration registers into working counters
                CntAddSrc <= unsigned(RegAddStartSrc);
                CntAddDst <= unsigned(RegAddStartDst);
                CntLgt <= unsigned(RegLgtTable);
                StateM <= RdAcc;

            when RdAcc => -- issue Avalon Master read at current source address
                if StopMaster = '0' then
                    avm_Add <= std_logic_vector(CntAddSrc);
                    avm_BE <= "1111";
                    avm_Rd <= '1';
                    CntAddSrc <= CntAddSrc + unsigned(RegNbByte);
                    StateM <= WaitRd;
                end if;

            when WaitRd => -- stall until Avalon fabric accepts the read (back-pressure)
                if avm_WaitRequest = '0' then
                    DataRd <= avm_RdData;
                    avm_Rd <= '0';
                    StateM <= WriteValue;
                end if;

            when WriteValue => -- issue Avalon Master write at current destination address
                if StopMaster = '0' then
                    avm_Add <= std_logic_vector(CntAddDst);
                    avm_BE <= "1111";
                    avm_Wr <= '1';
                    avm_WrData <= DataRd;
                    CntAddDst <= CntAddDst + unsigned(RegNbByte);
                    StateM <= WrEnd;
                end if;

            when WrEnd => -- stall until write is acknowledged
                if avm_WaitRequest = '0' then
                    avm_BE <= "0000";
                    avm_Wr <= '0';
                    CntLgt <= CntLgt - 1;
                    StateM <= EndTable;
                end if;

            when EndTable =>
                if CntLgt = "00000000000000000000000000000000" then
                    Finish <= '1';    -- signal transfer complete
                    IRQStatus <= '1'; -- raise IRQ to notify CPU
                    StateM <= Idle;
                else
                    StateM <= RdAcc; -- more elements remain; loop back
                end if;

        end case;
    end if;
end process AvalonMaster;

end architecture comp;
