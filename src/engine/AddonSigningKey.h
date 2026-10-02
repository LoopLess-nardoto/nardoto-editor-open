#pragma once

#include <array>
#include <cstdint>

// Trust root for .driftpkg addon packages. The matching Ed25519 private key lives outside both
// this repo and the addon repo (~/.config/nardoto/addon-signing.key) and never ships. Rotating it
// means shipping a new binary, so treat this array as an ABI.
//
// Nardoto: chave da loja propria (repositorio nardoto-editor-extras), gerada por
// scripts/loja/gerar-chave.mjs. Os pacotes sao montados e assinados por scripts/loja/empacotar.mjs.

namespace drift::addon {

inline constexpr std::array<std::uint8_t, 32> kSigningPublicKey = {
    0xaf, 0x5e, 0x9a, 0x01, 0xb1, 0xb2, 0x1b, 0x98, 0xa9, 0x6e, 0x5f,
    0x79, 0xe6, 0x92, 0xf5, 0x6a, 0xdd, 0x24, 0xc9, 0x4b, 0x3f, 0x3d,
    0xd5, 0x1e, 0xf3, 0xa7, 0xa8, 0xa2, 0x05, 0x13, 0xd9, 0xa6,
};

} // namespace drift::addon
