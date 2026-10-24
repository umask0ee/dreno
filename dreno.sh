#!/usr/bin/env bash
# dreno mede quanto um serviço custa de bateria no celular, com o medidor do próprio aparelho.
# precisa do pacote termux-api e do app termux:api. não acessa a rede e não pede root.
# licença MIT

set -u

VERSAO="0.1"
DIR="$(cd "$(dirname "$0")" && pwd)"
MEDICOES="$DIR/medicoes"
MINUTOS=5
INTERVALO="${DRENO_INTERVALO:-3}"     # segundos entre leituras
BLOCO="${DRENO_BLOCO:-30}"            # segundos por bloco na análise
ACOMODA="${DRENO_ACOMODA:-30}"        # segundos descartados no começo de cada fase
SEG_FASE="${DRENO_SEGUNDOS_FASE:-}"   # sobrescreve --minutos, só para teste

uso() {
  cat <<'EOF'
uso
  bash dreno.sh ruido [--minutos N]
  bash dreno.sh medir --nome NOME --iniciar "comando" [--parar "comando"] [--minutos N] [--capacidade MAH]
  bash dreno.sh medir --nome NOME --manual [--minutos N] [--capacidade MAH]
  bash dreno.sh analisar ARQUIVO [--capacidade MAH]
EOF
}

erro() { echo "$1" >&2; exit 1; }
inteiro() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }

# ---------- argumentos ----------

modo="${1:-}"
[ $# -gt 0 ] && shift
nome=""; iniciar=""; parar=""; manual=0; capacidade=""; arquivo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --manual) manual=1; shift ;;
    --nome|--iniciar|--parar|--minutos|--capacidade)
      [ $# -ge 2 ] || { uso; exit 1; }
      case "$1" in
        --nome) nome=$2 ;;
        --iniciar) iniciar=$2 ;;
        --parar) parar=$2 ;;
        --minutos) MINUTOS=$2 ;;
        --capacidade) capacidade=$2 ;;
      esac
      shift 2 ;;
    -h|--help) uso; exit 0 ;;
    *)
      [ -z "$arquivo" ] || { uso; exit 1; }
      arquivo=$1
      shift ;;
  esac
done

{ inteiro "$MINUTOS" && [ "$MINUTOS" -gt 0 ]; } || erro "o --minutos precisa ser um número inteiro maior que zero."
[ -z "$capacidade" ] || inteiro "$capacidade" || erro "o --capacidade vai em mAh, só com números."

# ---------- tela ----------

largura="${DRENO_COLUNAS:-$(stty size 2>/dev/null | cut -d' ' -f2)}"
inteiro "$largura" || largura=80

texto() { printf '%s\n' "$1" | fold -s -w "$largura"; }

# rótulo e valor, com o valor quebrado em linhas alinhadas na coluna dada
item() {
  local rotulo=$1 valor=$2 coluna=$3 recuo espaco parte primeira=1
  recuo=$(printf '%*s' "$coluna" '')
  espaco=$(( largura - coluna ))
  [ "$espaco" -lt 16 ] && espaco=16
  while IFS= read -r parte; do
    if [ "$primeira" -eq 1 ]; then
      printf '%s%s%s\n' "$rotulo" "${recuo:${#rotulo}}" "$parte"
      primeira=0
    else
      printf '%s%s\n' "$recuo" "$parte"
    fi
  done < <(printf '%s\n' "$valor" | fold -s -w "$espaco")
}

# ---------- aparelho e bateria ----------

prop() { command -v getprop >/dev/null 2>&1 && getprop "$1" 2>/dev/null; }

info_aparelho() {
  local fab mod
  fab=$(prop ro.product.manufacturer)
  mod=$(prop ro.product.model)
  case "$(echo "$mod" | tr '[:upper:]' '[:lower:]')" in
    "$(echo "$fab" | tr '[:upper:]' '[:lower:]')"*) aparelho="$mod" ;;
    *) aparelho="$fab $mod" ;;
  esac
  aparelho=$(echo "$aparelho" | sed 's/^ *//; s/ *$//')
  [ -z "$aparelho" ] && aparelho="desconhecido"
  soc=$(prop ro.soc.model)
  [ -z "$soc" ] && soc=$(prop ro.board.platform)
  [ -z "$soc" ] && soc="desconhecido"
}

campo() { printf '%s\n' "$1" | sed -n "s/.*\"$2\": *\(-\{0,1\}[0-9][0-9.]*\).*/\1/p" | head -n 1; }
campo_txt() { printf '%s\n' "$1" | sed -n "s/.*\"$2\": *\"\([A-Za-z_]*\)\".*/\1/p" | head -n 1; }

ler_bateria() {
  local json
  json=$(timeout 15 termux-battery-status 2>/dev/null) || return 1
  corrente=$(campo "$json" current)
  [ -n "$corrente" ] || return 1
  tensao=$(campo "$json" voltage)
  temp=$(campo "$json" temperature)
  pct=$(campo "$json" percentage)
  plug=$(campo_txt "$json" plugged)
  contador=$(campo "$json" charge_counter)
}

agora() {
  local t
  t=$(date +%s.%N 2>/dev/null)
  case "$t" in *N*|'') date +%s ;; *) echo "$t" ;; esac
}

# ---------- medição ----------

avisou_tomada=0
amostrar() {
  local fase=$1 duracao=$2
  SECONDS=0
  while [ "$SECONDS" -lt "$duracao" ]; do
    if ler_bateria; then
      printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(agora)" "$fase" "$corrente" "$tensao" "$temp" "$pct" "$plug" "$contador" >> "$arq"
      if [ -n "$plug" ] && [ "$plug" != "UNPLUGGED" ] && [ "$avisou_tomada" -eq 0 ]; then
        texto "o aparelho foi para a tomada. a medição continua, mas o resultado não vai valer."
        avisou_tomada=1
      fi
    fi
    sleep "$INTERVALO"
  done
}

servico_ligado=0
pid_servico=""

encerra_servico() {
  if [ -n "$parar" ]; then
    bash -c "$parar" >/dev/null 2>&1
  elif [ -n "$pid_servico" ]; then
    kill "$pid_servico" 2>/dev/null
  fi
  servico_ligado=0
  pid_servico=""
}

inicia_servico() {
  if [ "$manual" -eq 1 ]; then
    printf 'inicia o serviço agora e aperta enter. '
    read -r _
  else
    bash -c "$iniciar" >/dev/null 2>&1 &
    pid_servico=$!
  fi
  servico_ligado=1
}

para_servico() {
  if [ "$manual" -eq 1 ]; then
    printf 'para o serviço agora e aperta enter. '
    read -r _
    servico_ligado=0
  else
    encerra_servico
  fi
}

limpa() {
  if [ "$servico_ligado" -eq 1 ] && [ "$manual" -eq 0 ]; then
    encerra_servico
  fi
  if command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock >/dev/null 2>&1
  fi
  return 0
}

prepara() {
  command -v termux-battery-status >/dev/null 2>&1 \
    || erro "precisa do pacote termux-api (pkg install termux-api) e do app termux:api, baixado da mesma loja de onde veio o termux."
  ler_bateria || erro "o termux-battery-status não respondeu. confere se o app termux:api está instalado e com permissão."
  { [ -z "$plug" ] || [ "$plug" = "UNPLUGGED" ]; } || erro "tira o celular da tomada antes de medir."
  info_aparelho
  mkdir -p "$MEDICOES"
  trap limpa EXIT
  trap 'exit 130' INT TERM
  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock >/dev/null 2>&1
  fi
}

novo_arquivo() {
  local limpo
  limpo=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
  arq="$MEDICOES/$(date +%Y%m%d-%H%M%S)-$limpo.csv"
  {
    echo "# dreno $VERSAO"
    echo "# nome=$1"
    echo "# aparelho=$aparelho"
    echo "# soc=$soc"
    echo "# minutos=$MINUTOS"
    echo "# capacidade=$capacidade"
    echo "t,fase,corrente,tensao,temp,pct,plug,contador"
  } > "$arq"
}

# ---------- análise ----------
# as leituras viram médias por bloco, porque o medidor atualiza devagar e uma
# leitura depende da anterior. a comparação usa a média e o erro padrão dos blocos.

ANALISE=$(cat <<'AWK'
function abs(x) { return x < 0 ? -x : x }
# número inteiro com sinal, sem mostrar -0
function sn(x,    v) { v = sprintf("%.0f", x); if (v == "0" || v == "-0") return "0"; return (x > 0 ? "+" : "") v }
function variancia(s, s2, c,    v) {
  if (c < 2) return 0
  v = (s2 - s * s / c) / (c - 1)
  return v < 0 ? 0 : v
}
function calcula(f,    j, k, maxc, m, s, s2, c, pm, ps, ps2, pc) {
  maxc = 0
  for (j = 1; j <= nb[f]; j++) { k = f SUBSEP idx[f, j]; if (bn[k] > maxc) maxc = bn[k] }
  s = 0; s2 = 0; c = 0; ps = 0; ps2 = 0; pc = 0
  for (j = 1; j <= nb[f]; j++) {
    k = f SUBSEP idx[f, j]
    if (bn[k] < maxc / 2) continue
    m = bs[k] / bn[k] * fator
    s += m; s2 += m * m; c++
    if (bpn[k] > 0) {
      pm = bp[k] / bpn[k] * fator * vfator / 1000
      ps += pm; ps2 += pm * pm; pc++
    }
  }
  N[f] = c
  M[f] = c > 0 ? s / c : 0
  SD[f] = sqrt(variancia(s, s2, c))
  E[f] = c > 1 ? SD[f] / sqrt(c) : 0
  P[f] = pc > 0 ? ps / pc : -1
}
/^#/ {
  linha = substr($0, 3)
  p = index(linha, "=")
  if (p > 0) meta[substr(linha, 1, p - 1)] = substr(linha, p + 1)
  next
}
$1 == "t" || $3 == "" { next }
{
  t = $1 + 0; f = $2; i = $3 + 0
  if (!(f in t0)) { t0[f] = t; nf++; ordem[nf] = f }
  rel = t - t0[f]
  if ($7 != "" && $7 != "UNPLUGGED") tomada = 1
  if (i > 0) { pos++ } else if (i < 0) { neg++ }
  if (n > 0 && i != ult) mud++
  ult = i; n++
  if (n == 1) tini = t
  tfim = t
  soma_abs += abs(i)
  if ($5 != "") {
    tp = $5 + 0
    if (!tv || tp < tmin) tmin = tp
    if (!tv || tp > tmax) tmax = tp
    tv = 1
  }
  if ($4 != "") { vsoma += $4; vn++ }
  if ($6 != "") pct_ult = $6 + 0
  if ($8 != "") cont_ult = $8 + 0
  if (rel < acomoda) next
  b = int((rel - acomoda) / bloco)
  k = f SUBSEP b
  if (!(k in bn)) { nb[f]++; idx[f, nb[f]] = b }
  bs[k] += abs(i); bn[k]++
  if ($4 != "") { bp[k] += abs(i) * $4; bpn[k]++ }
}
END {
  print "n", n + 0
  if (n == 0) exit
  # miliampère ou microampère, pelo tamanho das leituras
  fator = (soma_abs / n < 5000) ? 1 : 0.001
  vfator = 1
  if (vn > 0 && vsoma / vn < 100) vfator = 1000
  for (x = 1; x <= nf; x++) calcula(ordem[x])

  print "tomada", tomada + 0
  print "misto", ((pos > 0 && neg > 0 && (pos < neg ? pos : neg) > 0.1 * n) ? 1 : 0)
  print "unidade", (fator == 1 ? "mili" : "micro")
  print "sinal", (pos > neg ? "invertido" : "padrao")
  if (mud > 0) {
    iv = (tfim - tini) / mud
    print "atualiza", (iv < 10 ? sprintf("%.1f", iv) : sprintf("%.0f", iv))
  } else print "atualiza", "?"
  print "temp_var", (tv ? sprintf("%.1f", tmax - tmin) : "?")
  print "temp_alta", ((tv && tmax - tmin > 3) ? 1 : 0)
  print "nome", meta["nome"]
  print "aparelho", meta["aparelho"]
  print "soc", meta["soc"]
  print "minutos", meta["minutos"]

  cap = (cap_arg + 0 > 0) ? cap_arg + 0 : meta["capacidade"] + 0
  if (cap <= 0 && cont_ult > 0 && pct_ult > 0) {
    cap = cont_ult / 1000 / (pct_ult / 100)
    if (cap < 1000 || cap > 12000) cap = 0
  }

  if ("teste" in N) {
    if (!("base1" in N) || !("base2" in N) || N["base1"] < 2 || N["teste"] < 2 || N["base2"] < 2) {
      print "modo", "incompleto"
      exit
    }
    print "modo", "medida"
    b1 = M["base1"]; b2 = M["base2"]; tt = M["teste"]
    base = (b1 + b2) / 2
    eb = sqrt(E["base1"] ^ 2 + E["base2"] ^ 2) / 2
    d = tt - base
    ed = sqrt(E["teste"] ^ 2 + eb ^ 2)
    printf "b1 %.0f\nb1e2 %.0f\nb2 %.0f\nb2e2 %.0f\n", b1, 2 * E["base1"], b2, 2 * E["base2"]
    printf "t %.0f\nte2 %.0f\n", tt, 2 * E["teste"]
    printf "delta %s\nic_min %s\nic_max %s\nic2 %.0f\n", sn(d), sn(d - 2 * ed), sn(d + 2 * ed), 2 * ed
    print "separa", (abs(d) > 2 * ed ? 1 : 0)
    dr = b2 - b1
    edr = sqrt(E["base1"] ^ 2 + E["base2"] ^ 2)
    print "drift", sn(dr)
    print "drift_alto", ((abs(dr) > 2 * edr && abs(dr) > 0.5 * abs(d)) ? 1 : 0)
    nmin = N["base1"]
    if (N["teste"] < nmin) nmin = N["teste"]
    if (N["base2"] < nmin) nmin = N["base2"]
    print "nmin", nmin
    if (P["base1"] >= 0 && P["base2"] >= 0 && P["teste"] >= 0)
      print "p_delta", sn(P["teste"] - (P["base1"] + P["base2"]) / 2)
    if (cap > 0) {
      printf "cap %.0f\npct_h %.1f\n", cap, d / cap * 100
      if (pct_ult > 0 && tt > 0) printf "autonomia %.1f\npct %d\n", cap * pct_ult / 100 / tt, pct_ult
    }
  } else {
    print "modo", "ruido"
    f = ("base" in N) ? "base" : ordem[1]
    # diferença mínima detectável num teste com fases do mesmo tamanho
    printf "m %.0f\ne2 %.0f\nsd %.0f\nmde %.0f\nnblocos %d\n", M[f], 2 * E[f], SD[f], 3.4 * E[f], N[f]
    if (P[f] >= 0) printf "p %.0f\n", P[f]
  }
}
AWK
)

relatorio() {
  local arquivo=$1 chave valor unidade_txt sinal_txt potencia bateria a
  local -A R=()
  local -a avisos=()
  while read -r chave valor; do
    R[$chave]=$valor
  done < <(awk -F, -v acomoda="$ACOMODA" -v bloco="$BLOCO" -v cap_arg="$capacidade" "$ANALISE" "$arquivo")

  if [ "${R[n]:-0}" -eq 0 ]; then
    echo "nenhuma leitura no arquivo."
    return 1
  fi

  if [ "${R[unidade]}" = "mili" ]; then unidade_txt="miliampère"; else unidade_txt="microampère"; fi
  if [ "${R[sinal]}" = "invertido" ]; then sinal_txt="invertido"; else sinal_txt="padrão"; fi

  echo
  case "${R[modo]}" in
    incompleto)
      texto "a medição não tem as três fases completas, então não dá para comparar."
      return 1 ;;
    ruido)
      item "consumo médio" "${R[m]} mA ± ${R[e2]}" 16
      [ -n "${R[p]:-}" ] && item "potência" "${R[p]} mW" 16
      item "oscilação" "${R[sd]} mA entre blocos de $BLOCO s" 16
      item "medidor" "corrente em $unidade_txt, sinal $sinal_txt, atualiza a cada ~${R[atualiza]} s" 16
      echo
      texto "com ${R[minutos]} min por fase, diferenças abaixo de uns ${R[mde]} mA não aparecem na medição."
      [ "${R[nblocos]}" -lt 4 ] && avisos+=("poucos blocos para uma estimativa firme. aumenta o --minutos.")
      ;;
    medida)
      item "linha de base" "${R[b1]} mA ± ${R[b1e2]} antes e ${R[b2]} mA ± ${R[b2e2]} depois" 16
      item "com o serviço" "${R[t]} mA ± ${R[te2]}" 16
      if [ "${R[separa]}" -eq 1 ]; then
        item "diferença" "${R[delta]} mA, entre ${R[ic_min]} e ${R[ic_max]}" 16
      else
        item "diferença" "${R[delta]} mA, sem se separar do ruído" 16
      fi
      [ -n "${R[p_delta]:-}" ] && item "potência" "${R[p_delta]} mW" 16
      [ -n "${R[pct_h]:-}" ] && item "bateria" "${R[pct_h]}% por hora a mais, com ${R[cap]} mAh de capacidade" 16
      [ -n "${R[autonomia]:-}" ] && item "autonomia" "uns ${R[autonomia]} h nesse estado, com ${R[pct]}% de carga" 16
      item "medidor" "corrente em $unidade_txt, sinal $sinal_txt, atualiza a cada ~${R[atualiza]} s" 16
      [ "${R[drift_alto]}" -eq 1 ] && avisos+=("a linha de base mudou ${R[drift]} mA entre o começo e o fim. repete com o aparelho parado e longe de calor.")
      [ "${R[separa]}" -eq 0 ] && avisos+=("a diferença não se separou do ruído. tenta de novo com mais minutos por fase.")
      [ "${R[nmin]}" -lt 4 ] && avisos+=("poucos blocos por fase. aumenta o --minutos para um resultado mais firme.")
      ;;
  esac

  [ "${R[tomada]}" -eq 1 ] && avisos+=("o aparelho esteve na tomada durante a medição, então o resultado não vale. repete com ele desconectado.")
  [ "${R[misto]}" -eq 1 ] && avisos+=("a corrente trocou de sinal no meio da medição, o que costuma ser carregador ou medidor instável.")
  [ "${R[temp_alta]}" -eq 1 ] && avisos+=("a temperatura variou ${R[temp_var]} °C durante a medição, e isso mexe no consumo.")

  if [ "${#avisos[@]}" -gt 0 ]; then
    echo
    for a in "${avisos[@]}"; do texto "$a"; done
  fi

  if [ "${R[modo]}" = "medida" ] && [ "${R[separa]}" -eq 1 ] && [ "${R[tomada]}" -eq 0 ]; then
    if [ -n "${R[p_delta]:-}" ]; then potencia="${R[p_delta]} mW"; else potencia="sem leitura"; fi
    if [ -n "${R[pct_h]:-}" ]; then bateria="${R[pct_h]} %/h"; else bateria="sem leitura"; fi
    echo
    echo "linha para a tabela de energia"
    echo "| ${R[nome]} | ${R[aparelho]} | ${R[soc]} | ${R[delta]} mA (±${R[ic2]}) | $potencia | $bateria | ${R[minutos]} min por fase |"
  fi
  return 0
}

# ---------- principal ----------

if [ -n "$SEG_FASE" ]; then duracao=$SEG_FASE; else duracao=$((MINUTOS * 60)); fi

case "$modo" in
  ruido)
    prepara
    novo_arquivo "ruido"
    echo "dreno $VERSAO"
    texto "medindo $MINUTOS min com o aparelho parado. pode apagar a tela, o termux segura o processador acordado até o fim."
    amostrar base "$duracao"
    relatorio "$arq"
    echo
    texto "medição salva em medicoes/$(basename "$arq")"
    ;;
  medir)
    [ -n "$nome" ] || erro "falta o --nome do serviço."
    [ -n "$iniciar" ] || [ "$manual" -eq 1 ] || erro "passa o --iniciar com o comando do serviço, ou usa --manual."
    prepara
    novo_arquivo "$nome"
    echo "dreno $VERSAO"
    texto "são três fases de $MINUTOS min, sem o serviço, com o serviço e sem de novo. o teste todo leva $((MINUTOS * 3)) min."
    if [ "$manual" -eq 1 ]; then
      texto "deixa a tela do mesmo jeito nas três fases."
    else
      texto "pode apagar a tela, o termux segura o processador acordado até o fim."
    fi
    echo
    echo "fase 1 de 3, linha de base"
    amostrar base1 "$duracao"
    echo "fase 2 de 3, com o serviço"
    inicia_servico
    amostrar teste "$duracao"
    para_servico
    echo "fase 3 de 3, linha de base de novo"
    amostrar base2 "$duracao"
    relatorio "$arq"
    echo
    texto "medição salva em medicoes/$(basename "$arq")"
    ;;
  analisar)
    { [ -n "$arquivo" ] && [ -r "$arquivo" ]; } || erro "passa o arquivo da medição, que fica em medicoes/."
    relatorio "$arquivo"
    ;;
  *)
    uso
    exit 1 ;;
esac
