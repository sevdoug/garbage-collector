# Garbage Collector

App de macOS para ver o que está ocupando o disco e mandar o que não presta para a Lixeira.

- **Lista** da pasta atual, do maior para o menor, com barra proporcional e % da pasta.
- **Treemap** ao lado: a área de cada bloco é o espaço que ele ocupa; as cores batem com a lista.
- **Maiores arquivos**: os 200 maiores de toda a árvore, independente da pasta.
- **Lixeira**: seleciona, confirma, vai para a Lixeira do macOS. Nada é apagado direto.

SwiftUI + SwiftPM, sem dependências. O `.app` tem ~1 MB.

## Rodar

Requer macOS 14+ e Xcode (ou Command Line Tools) com Swift 6.

```bash
scripts/bundle.sh            # gera dist/Garbage Collector.app
open "dist/Garbage Collector.app"
```

```bash
scripts/bundle.sh --install  # gera e copia para /Applications
```

Para abrir já escaneando uma pasta:

```bash
open "dist/Garbage Collector.app" --args /caminho/da/pasta
```

Durante o desenvolvimento, `swift run GarbageCollector` também funciona (sem ícone nem Info.plist).

## Usar

| Ação | Como |
| --- | --- |
| Entrar em uma pasta | duplo clique na lista ou no treemap, ou Return |
| Voltar | ⌘↑, o botão ⌃ da barra, ou um trecho do caminho no topo |
| Selecionar vários | ⌘-clique / ⇧-clique na lista; ⌘-clique no treemap |
| Mover para a Lixeira | ⌘⌫, o botão no rodapé, ou clique direito |
| Mostrar no Finder / copiar caminho | clique direito |
| Escanear de novo | ⌘R (volta para a pasta em que você estava) |
| Escolher outra pasta | ⌘O |

Em cada pasta, os arquivos menores que 1 MB aparecem somados em uma linha só
("N arquivos menores que 1 MB"). **Detalhar** lista os 1.000 maiores deles.

O espaço só volta de verdade quando você **esvazia a Lixeira** — o rodapé mostra quanto já foi
para lá na sessão e tem um atalho para abri-la.

## Permissões

O macOS protege algumas pastas. Sem permissão o app continua funcionando, mas essas pastas ficam
de fora da conta e aparecem no aviso "N pastas não lidas" do rodapé.

Para enxergar tudo: **Ajustes do Sistema → Privacidade e Segurança → Acesso Total ao Disco** e
adicione o Garbage Collector. Depois escaneie de novo.

O app é assinado ad-hoc (sem certificado de desenvolvedor). O macOS amarra a permissão a essa
assinatura, então **depois de recompilar pode ser preciso conceder o acesso de novo**.

## Como o tamanho é contado

Mesmas regras do `du`, e os totais batem com ele:

- **Tamanho alocado em disco**, não o tamanho lógico. Arquivos esparsos (ex.: `Docker.raw`) e
  arquivos que só existem no iCloud contam o que realmente ocupam.
- **Hardlinks contam uma vez só** — o primeiro caminho encontrado leva o tamanho.
- **Links simbólicos não são seguidos.**
- **Não atravessa volumes**: discos externos montados dentro da pasta aparecem como "outro volume".
- **Pastas só na nuvem não são listadas** (listar forçaria o download).

"Disco inteiro" escaneia o volume de dados (`/System/Volumes/Data`), onde ficam seus arquivos,
apps e a biblioteca do sistema. O volume do sistema (selado, só leitura) fica de fora.

## Travas de segurança

O app se recusa a mandar para a Lixeira pastas estruturais: a raiz do disco, pastas do sistema,
raízes de volumes, sua pasta pessoal, as pastas padrão dela (`Documentos`, `Downloads`,
`Biblioteca`…) e o primeiro nível de `~/Library`. O **conteúdo** delas continua liberado.
As regras estão em `Sources/ScanCore/TrashGuard.swift` e têm teste para cada caso.

A checagem é refeita contra o disco no instante de mover: se desde o scan alguma pasta do
caminho virou um link simbólico (ou seja, o caminho passou a apontar para outro lugar), o item
é recusado e o app pede um novo scan.

## Limitações conhecidas

- **O espaço liberado pode ser menor que o mostrado** quando há hardlinks (ex.: `node_modules` do
  pnpm, que aponta para a store) ou clones APFS (cópias feitas no Finder): o espaço só volta quando
  some o último caminho que aponta para os dados.
- **Snapshots locais do Time Machine e espaço "purgável"** não aparecem no scan, então o total
  pode ser menor que o "usado" que o macOS informa.
- **A árvore é uma foto do momento do scan.** Mudanças feitas por fora só aparecem ao escanear de
  novo. Se um item selecionado já não existir, ele só sai da lista.
- **"Colocar de Volta"**: a Lixeira é acionada pela API que move "do mesmo jeito que o Finder"
  (`NSWorkspace.recycle`), mas a opção "Colocar de Volta" não foi conferida manualmente.
- Só macOS. Não esvazia a Lixeira nem apaga em definitivo (de propósito).

## Código

```
Sources/ScanCore/          lógica pura, sem UI
  Scanner.swift            scan paralelo (readdir + fstatat), agregação e progresso
  DirectoryReader.swift    leitura de baixo nível de uma pasta
  FileNode.swift           nó da árvore
  TreeEditor.swift         remover nó, detalhar arquivos pequenos, maiores arquivos
  Treemap.swift            layout "squarified"
  TrashGuard.swift         o que pode ou não ir para a Lixeira
Sources/GarbageCollector/  app SwiftUI
  AppModel.swift           estado: scan, navegação, seleção, lixeira
  BrowserView.swift        janela principal, caminho, rodapé, avisos
  ItemListView.swift       lista e "Maiores arquivos"
  TreemapView.swift        treemap (Canvas)
scripts/bundle.sh          monta o .app
scripts/make-icon.sh       regera Resources/AppIcon.icns
```

## Testes

```bash
swift test
```

Os testes criam pastas temporárias com os casos difíceis (arquivo esparso, hardlink, link
simbólico em loop, pasta sem permissão) e comparam os totais com o `du -sk`.

Para medir tempo e memória em uma pasta real (somente leitura):

```bash
GC_BENCH_PATH=~/Library swift test -c release -Xswiftc -enable-testing --filter benchmark
```

Referência (MacBook com Apple Silicon, cache frio):

| Alvo | Arquivos | Tamanho | Tempo | Pico de memória |
| --- | --- | --- | --- | --- |
| `~/Library` | 1,26 milhão | 149 GiB | 12,5 s | 80 MiB |
| Disco inteiro (`/System/Volumes/Data`) | 4,4 milhões | 388 GiB | 29 s | 213 MiB |
