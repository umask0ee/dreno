# dreno

Mede quanto um serviço ou app custa de bateria no celular, usando o medidor de carga do próprio aparelho. Não precisa de equipamento nenhum.

## Como funciona

A medição tem três fases do mesmo tamanho. Primeiro a linha de base, depois o serviço rodando, depois a linha de base de novo. A segunda linha de base mostra se o consumo do aparelho mudou sozinho durante o teste, e o resultado usa a média das duas.

As leituras são agrupadas em blocos de 30 segundos, porque o medidor do celular atualiza devagar e uma leitura depende da anterior. A comparação entre as fases sai com um intervalo aproximado de 95%. Se a diferença não se separa do ruído, o script avisa e não dá número para a tabela.

O script segura o processador acordado durante a medição, então o resultado é o custo do serviço com o aparelho acordado. É o caso de quem deixa o celular ligado como servidor.

## Instalando

```
pkg install git termux-api
git clone https://github.com/umask0ee/dreno
cd dreno
```

Instale também o app Termux:API, baixado da mesma loja de onde veio o Termux. Durante a medição, o celular precisa ficar fora da tomada.

## Usando

Comece medindo o ruído do seu aparelho.

```
bash dreno.sh ruido
```

São cinco minutos parado, e no fim ele diz a menor diferença que dá para detectar no seu medidor.

Para medir um serviço, passe o comando que inicia e o que para.

```
bash dreno.sh medir --nome syncthing --iniciar "syncthing --no-browser" --parar "pkill syncthing"
```

Sem comando, use `--manual` e o script pede para você iniciar e parar o serviço na hora certa. Nesse modo a tela fica acesa nas transições, então compare só com medições feitas do mesmo jeito.

Outras opções

- `--minutos N` muda o tempo de cada fase. O padrão é 5, e o teste completo leva o triplo.
- `--capacidade MAH` informa a capacidade da bateria quando o aparelho não informa sozinho.

Cada medição fica salva em `medicoes/`, e `bash dreno.sh analisar ARQUIVO` refaz a análise de um arquivo salvo.

## O que ele lê

Corrente, tensão, temperatura, porcentagem, carga restante e se o aparelho está na tomada, tudo pelo termux-battery-status. Lê também o modelo e o SoC, para a tabela.

## O que ele não faz

Não acessa a rede, não pede root e não coleta serial, IMEI, conta ou qualquer coisa que identifique a pessoa.

## Limites

Cada fabricante reporta a corrente de um jeito. Alguns usam microampère, outros miliampère, e alguns invertem o sinal. O script detecta isso pelo tamanho e pelo sinal das leituras, e o `ruido` mostra o que foi detectado. Um aparelho muito fora do padrão pode enganar essa detecção.

Tela, temperatura e outros apps abertos mexem no consumo. Para um resultado confiável, deixe o aparelho parado, longe de calor e com a tela no mesmo estado nas três fases.

## Contribuindo com a tabela

No fim de cada medição que se separa do ruído sai uma linha para `energia.md`. Mande no tópico do projeto ou abra um pull request.

## Licença

MIT.
