// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice CCIP chain-specific constants used across Juicebox sucker contracts.
library CCIPHelper {
    error CCIPHelper_UnsupportedChain(uint256 chainId);
    /// @notice The respective CCIP router used by the chain
    address public constant ETH_ROUTER = 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D;
    address public constant ETH_SEP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address public constant OP_ROUTER = 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f;
    address public constant OP_SEP_ROUTER = 0x114A20A10b43D4115e5aeef7345a1A71d2a60C57;
    address public constant ARB_ROUTER = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;
    address public constant ARB_SEP_ROUTER = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    address public constant POLY_ROUTER = 0x849c5ED5a80F5B408Dd4969b78c2C8fdf0565Bfe;
    address public constant AVA_ROUTER = 0xF4c7E640EdA248ef95972845a62bdC74237805dB;
    address public constant BNB_ROUTER = 0x34B03Cb9086d7D758AC55af71584F81A598759FE;
    address public constant BASE_ROUTER = 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD;
    address public constant BASE_SEP_ROUTER = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
    address public constant TEMPO_ROUTER = 0xa132F089492CcE5f1D79483a9e4552f37266ed01;
    address public constant TEMPO_MOD_ROUTER = 0xD3e53cCEE3688aAEE5C9118ef5Fe24EB423aa56F;

    /// @notice The respective chain ids per network
    uint256 public constant ETH_ID = 1;
    uint256 public constant ETH_SEP_ID = 11_155_111;
    uint256 public constant OP_ID = 10;
    uint256 public constant OP_SEP_ID = 11_155_420;
    uint256 public constant ARB_ID = 42_161;
    uint256 public constant ARB_SEP_ID = 421_614;
    uint256 public constant POLY_ID = 137;
    uint256 public constant AVA_ID = 43_114;
    uint256 public constant BNB_ID = 56;
    uint256 public constant BASE_ID = 8453;
    uint256 public constant BASE_SEP_ID = 84_532;
    uint256 public constant TEMPO_ID = 4217;
    uint256 public constant TEMPO_MOD_ID = 42_431;

    /// @notice The chain selector per network
    uint64 public constant ETH_SEL = 5_009_297_550_715_157_269;
    uint64 public constant ETH_SEP_SEL = 16_015_286_601_757_825_753;
    uint64 public constant OP_SEL = 3_734_403_246_176_062_136;
    uint64 public constant OP_SEP_SEL = 5_224_473_277_236_331_295;
    uint64 public constant ARB_SEL = 4_949_039_107_694_359_620;
    uint64 public constant ARB_SEP_SEL = 3_478_487_238_524_512_106;
    uint64 public constant POLY_SEL = 4_051_577_828_743_386_545;
    uint64 public constant AVA_SEL = 6_433_500_567_565_415_381;
    uint64 public constant BNB_SEL = 11_344_663_589_394_136_015;
    uint64 public constant BASE_SEL = 15_971_525_489_660_198_786;
    uint64 public constant BASE_SEP_SEL = 10_344_971_235_874_465_080;
    uint64 public constant TEMPO_SEL = 7_281_642_695_469_137_430;
    uint64 public constant TEMPO_MOD_SEL = 8_457_817_439_310_187_923;

    /// @notice The LINK token address of each chain
    address public constant ETH_LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address public constant ETH_SEP_LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address public constant OP_LINK = 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6;
    address public constant OP_SEP_LINK = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;
    address public constant ARB_LINK = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
    address public constant ARB_SEP_LINK = 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E;
    address public constant BASE_LINK = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;
    address public constant BASE_SEP_LINK = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410;
    address public constant TEMPO_LINK = 0x15C03488B29e27d62BAf10E30b0c474bf60E0264;
    address public constant TEMPO_MOD_LINK = 0xEAB080c724587fFC9F2EFF82e36EE4Fb27774959;

    /// @notice The WETH address of each chain
    address public constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant ETH_SEP_WETH = 0x097D90c9d3E0B50Ca60e1ae45F6A81010f9FB534;
    address public constant OP_WETH = 0x4200000000000000000000000000000000000006;
    address public constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant ARB_SEP_WETH = 0xE591bf0A0CF924A0674d7792db046B23CEbF5f34;
    address public constant POLY_WETH = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address public constant AVA_WETH = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address public constant BNB_WETH = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address public constant OP_SEP_WETH = 0x4200000000000000000000000000000000000006;
    address public constant BASE_SEP_WETH = 0x4200000000000000000000000000000000000006;
    address public constant TEMPO_WETH = 0xC5D538C96D6FEE7E6DFE7248B32898087b22ba79;
    address public constant TEMPO_MOD_WETH = 0xbb2D3310E4232085d432A2e04b2Ac09c46F634E4;

    /// @notice Returns the CCIP router address for a given chain ID.
    /// @param chainId The EVM chain ID to look up.
    /// @return router The CCIP router address.
    function routerOfChain(uint256 chainId) internal pure returns (address router) {
        if (chainId == ETH_ID) {
            return ETH_ROUTER;
        } else if (chainId == OP_ID) {
            return OP_ROUTER;
        } else if (chainId == ARB_ID) {
            return ARB_ROUTER;
        } else if (chainId == POLY_ID) {
            return POLY_ROUTER;
        } else if (chainId == AVA_ID) {
            return AVA_ROUTER;
        } else if (chainId == BNB_ID) {
            return BNB_ROUTER;
        } else if (chainId == BASE_ID) {
            return BASE_ROUTER;
        } else if (chainId == ETH_SEP_ID) {
            return ETH_SEP_ROUTER;
        } else if (chainId == ARB_SEP_ID) {
            return ARB_SEP_ROUTER;
        } else if (chainId == OP_SEP_ID) {
            return OP_SEP_ROUTER;
        } else if (chainId == BASE_SEP_ID) {
            return BASE_SEP_ROUTER;
        } else if (chainId == TEMPO_ID) {
            return TEMPO_ROUTER;
        } else if (chainId == TEMPO_MOD_ID) {
            return TEMPO_MOD_ROUTER;
        } else {
            revert CCIPHelper_UnsupportedChain(chainId);
        }
    }

    /// @notice Returns the CCIP chain selector for a given chain ID.
    /// @param chainId The EVM chain ID to look up.
    /// @return selectorId The CCIP chain selector.
    function selectorOfChain(uint256 chainId) internal pure returns (uint64 selectorId) {
        if (chainId == ETH_ID) {
            return ETH_SEL;
        } else if (chainId == OP_ID) {
            return OP_SEL;
        } else if (chainId == ARB_ID) {
            return ARB_SEL;
        } else if (chainId == POLY_ID) {
            return POLY_SEL;
        } else if (chainId == AVA_ID) {
            return AVA_SEL;
        } else if (chainId == BNB_ID) {
            return BNB_SEL;
        } else if (chainId == BASE_ID) {
            return BASE_SEL;
        } else if (chainId == ETH_SEP_ID) {
            return ETH_SEP_SEL;
        } else if (chainId == ARB_SEP_ID) {
            return ARB_SEP_SEL;
        } else if (chainId == OP_SEP_ID) {
            return OP_SEP_SEL;
        } else if (chainId == BASE_SEP_ID) {
            return BASE_SEP_SEL;
        } else if (chainId == TEMPO_ID) {
            return TEMPO_SEL;
        } else if (chainId == TEMPO_MOD_ID) {
            return TEMPO_MOD_SEL;
        } else {
            revert CCIPHelper_UnsupportedChain(chainId);
        }
    }

    /// @notice Returns the WETH address for a given chain ID.
    /// @param chainId The EVM chain ID to look up.
    /// @return weth The WETH address.
    function wethOfChain(uint256 chainId) public pure returns (address weth) {
        if (chainId == ETH_ID) {
            return ETH_WETH;
        } else if (chainId == OP_ID) {
            return OP_WETH;
        } else if (chainId == ARB_ID) {
            return ARB_WETH;
        } else if (chainId == POLY_ID) {
            return POLY_WETH;
        } else if (chainId == AVA_ID) {
            return AVA_WETH;
        } else if (chainId == BNB_ID) {
            return BNB_WETH;
        } else if (chainId == BASE_ID) {
            return BASE_WETH;
        } else if (chainId == ETH_SEP_ID) {
            return ETH_SEP_WETH;
        } else if (chainId == ARB_SEP_ID) {
            return ARB_SEP_WETH;
        } else if (chainId == OP_SEP_ID) {
            return OP_SEP_WETH;
        } else if (chainId == BASE_SEP_ID) {
            return BASE_SEP_WETH;
        } else if (chainId == TEMPO_ID) {
            return TEMPO_WETH;
        } else if (chainId == TEMPO_MOD_ID) {
            return TEMPO_MOD_WETH;
        } else {
            revert CCIPHelper_UnsupportedChain(chainId);
        }
    }

    /// @notice Returns the LINK token address for a given chain ID.
    /// @param chainId The EVM chain ID to look up.
    /// @return link The LINK token address.
    function linkOfChain(uint256 chainId) public pure returns (address link) {
        if (chainId == ETH_ID) {
            return ETH_LINK;
        } else if (chainId == OP_ID) {
            return OP_LINK;
        } else if (chainId == ARB_ID) {
            return ARB_LINK;
        } else if (chainId == BASE_ID) {
            return BASE_LINK;
        } else if (chainId == ETH_SEP_ID) {
            return ETH_SEP_LINK;
        } else if (chainId == OP_SEP_ID) {
            return OP_SEP_LINK;
        } else if (chainId == ARB_SEP_ID) {
            return ARB_SEP_LINK;
        } else if (chainId == BASE_SEP_ID) {
            return BASE_SEP_LINK;
        } else if (chainId == TEMPO_ID) {
            return TEMPO_LINK;
        } else if (chainId == TEMPO_MOD_ID) {
            return TEMPO_MOD_LINK;
        } else {
            revert CCIPHelper_UnsupportedChain(chainId);
        }
    }
}
