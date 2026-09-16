#!/usr/bin/env node
// Monta o .ico (Windows) e o .icns (macOS) do Nardoto Editor a partir de PNGs
// já redimensionados, sem depender de pacote nenhum: os dois formatos aceitam
// PNG embutido, então o arquivo é só um cabeçalho mais os PNGs em sequência.
//
// Uso: node scripts/montar-icones.js <pasta com 16.png ... 1024.png>
// Saída: resources/windows/nardoto-editor.ico e resources/macos/NardotoEditor.icns

const fs = require('fs')
const path = require('path')

const pasta = process.argv[2]
if (!pasta) {
  console.error('Informe a pasta com os PNGs (16.png, 24.png, ..., 1024.png).')
  process.exit(1)
}
const raiz = path.resolve(__dirname, '..')
const png = (n) => fs.readFileSync(path.join(pasta, `${n}.png`))

// ICO: cabeçalho de 6 bytes + uma entrada de 16 bytes por imagem + os PNGs.
function montarIco(tamanhos) {
  const imagens = tamanhos.map((n) => ({ n, dados: png(n) }))
  const cabecalho = Buffer.alloc(6)
  cabecalho.writeUInt16LE(0, 0)
  cabecalho.writeUInt16LE(1, 2)
  cabecalho.writeUInt16LE(imagens.length, 4)
  const entradas = []
  let deslocamento = 6 + 16 * imagens.length
  for (const { n, dados } of imagens) {
    const e = Buffer.alloc(16)
    e.writeUInt8(n >= 256 ? 0 : n, 0)
    e.writeUInt8(n >= 256 ? 0 : n, 1)
    e.writeUInt8(0, 2)
    e.writeUInt8(0, 3)
    e.writeUInt16LE(1, 4)
    e.writeUInt16LE(32, 6)
    e.writeUInt32LE(dados.length, 8)
    e.writeUInt32LE(deslocamento, 12)
    deslocamento += dados.length
    entradas.push(e)
  }
  return Buffer.concat([cabecalho, ...entradas, ...imagens.map((i) => i.dados)])
}

// ICNS: 'icns' + tamanho total, depois blocos "tipo + tamanho + PNG".
// Os tipos @2x repetem o PNG do dobro do tamanho, como o Finder espera.
function montarIcns() {
  const blocos = [
    ['icp4', 16], ['icp5', 32], ['icp6', 64],
    ['ic07', 128], ['ic08', 256], ['ic09', 512], ['ic10', 1024],
    ['ic11', 32], ['ic12', 64], ['ic13', 256], ['ic14', 512],
  ].map(([tipo, n]) => {
    const dados = png(n)
    const cab = Buffer.alloc(8)
    cab.write(tipo, 0, 'ascii')
    cab.writeUInt32BE(dados.length + 8, 4)
    return Buffer.concat([cab, dados])
  })
  const corpo = Buffer.concat(blocos)
  const cab = Buffer.alloc(8)
  cab.write('icns', 0, 'ascii')
  cab.writeUInt32BE(corpo.length + 8, 4)
  return Buffer.concat([cab, corpo])
}

const ico = path.join(raiz, 'resources', 'windows', 'nardoto-editor.ico')
const icns = path.join(raiz, 'resources', 'macos', 'NardotoEditor.icns')
fs.writeFileSync(ico, montarIco([16, 24, 32, 48, 64, 128, 256]))
fs.writeFileSync(icns, montarIcns())
console.log(`gravado ${ico} (${fs.statSync(ico).size} bytes)`)
console.log(`gravado ${icns} (${fs.statSync(icns).size} bytes)`)
