-- #############################################################################
-- DE1_SoC_top_level.vhd
--
-- BOARD         : DE1-SoC from Terasic
-- Author        : Sahand Kashani-Akhavan from Terasic documentation
-- Revision      : 1.4
-- Creation date : 04/02/2015
--
-- Syntax Rule : GROUP_NAME_N[bit]
--
-- GROUP  : specify a particular interface (ex: SDR_)
-- NAME   : signal name (ex: CONFIG, D, ...)
-- bit    : signal index
-- _N     : to specify an active-low signal
-- #############################################################################

library ieee;
use ieee.std_logic_1164.all;

entity DE1_SoC_top_level is
    port(
        -- Audio
        AUD_ADCDAT       : in    std_logic;
        AUD_ADCLRCK      : inout std_logic;
        AUD_BCLK         : inout std_logic;
        AUD_DACDAT       : out   std_logic;
        AUD_DACLRCK      : inout std_logic;
        AUD_XCK          : out   std_logic;

        -- CLOCK
        CLOCK_50         : in    std_logic;

        -- SDRAM
        DRAM_ADDR        : out   std_logic_vector(12 downto 0);
        DRAM_BA          : out   std_logic_vector(1 downto 0);
        DRAM_CAS_N       : out   std_logic;
        DRAM_CKE         : out   std_logic;
        DRAM_CLK         : out   std_logic;
        DRAM_CS_N        : out   std_logic;
        DRAM_DQ          : inout std_logic_vector(15 downto 0);
        DRAM_LDQM        : out   std_logic;
        DRAM_RAS_N       : out   std_logic;
        DRAM_UDQM        : out   std_logic;
        DRAM_WE_N        : out   std_logic;

        -- I2C for Audio and Video-In
        FPGA_I2C_SCLK    : out   std_logic;
        FPGA_I2C_SDAT    : inout std_logic;

        -- KEY_N
        KEY_N            : in    std_logic_vector(3 downto 0);

        -- SW
        SW               : in    std_logic_vector(9 downto 0)
    );
end entity DE1_SoC_top_level;

architecture rtl of DE1_SoC_top_level is

component Audio_System is
        port (
            audio_0_external_interface_ADCDAT                : in    std_logic                     := 'X';
            audio_0_external_interface_ADCLRCK               : in    std_logic                     := 'X';
            audio_0_external_interface_BCLK                  : in    std_logic                     := 'X';
            audio_0_external_interface_DACDAT                : out   std_logic;
            audio_0_external_interface_DACLRCK               : in    std_logic                     := 'X';
            audio_and_video_config_0_external_interface_SDAT : inout std_logic                     := 'X';
            audio_and_video_config_0_external_interface_SCLK : out   std_logic;
            audio_pll_0_audio_clk_clk                        : out   std_logic;
            clk_clk                                          : in    std_logic                     := 'X';
            pio_0_external_connection_export                 : in    std_logic_vector(7 downto 0)  := (others => 'X');
            pll_0_outclk2_clk                                : out   std_logic;
            reset_reset_n                                    : in    std_logic                     := 'X';
            sdram_controller_0_wire_addr                     : out   std_logic_vector(12 downto 0);
            sdram_controller_0_wire_ba                       : out   std_logic_vector(1 downto 0);
            sdram_controller_0_wire_cas_n                    : out   std_logic;
            sdram_controller_0_wire_cke                      : out   std_logic;
            sdram_controller_0_wire_cs_n                     : out   std_logic;
            sdram_controller_0_wire_dq                       : inout std_logic_vector(15 downto 0) := (others => 'X');
            sdram_controller_0_wire_dqm                      : out   std_logic_vector(1 downto 0);
            sdram_controller_0_wire_ras_n                    : out   std_logic;
            sdram_controller_0_wire_we_n                     : out   std_logic
        );
    end component Audio_System;

begin
    u0 : component Audio_System
        port map (
            audio_0_external_interface_ADCDAT                => AUD_ADCDAT,
            audio_0_external_interface_ADCLRCK               => AUD_ADCLRCK,
            audio_0_external_interface_BCLK                  => AUD_BCLK,
            audio_0_external_interface_DACDAT                => AUD_DACDAT,
            audio_0_external_interface_DACLRCK               => AUD_DACLRCK,
            audio_and_video_config_0_external_interface_SDAT => FPGA_I2C_SDAT,
            audio_and_video_config_0_external_interface_SCLK => FPGA_I2C_SCLK,
            audio_pll_0_audio_clk_clk                        => AUD_XCK,
            clk_clk                                          => CLOCK_50,
            pio_0_external_connection_export                 => SW(7 downto 0),
            pll_0_outclk2_clk                                => DRAM_CLK,
            reset_reset_n                                    => KEY_N(0),
            sdram_controller_0_wire_addr                     => DRAM_ADDR,
            sdram_controller_0_wire_ba                       => DRAM_BA,
            sdram_controller_0_wire_cas_n                    => DRAM_CAS_N,
            sdram_controller_0_wire_cke                      => DRAM_CKE,
            sdram_controller_0_wire_cs_n                     => DRAM_CS_N,
            sdram_controller_0_wire_dq                       => DRAM_DQ,
            sdram_controller_0_wire_dqm(0)                   => DRAM_LDQM,
            sdram_controller_0_wire_dqm(1)                   => DRAM_UDQM,
            sdram_controller_0_wire_ras_n                    => DRAM_RAS_N,
            sdram_controller_0_wire_we_n                     => DRAM_WE_N
        );

end;
