"""
Config
======
Lê o .env SEM poluir os.environ. Isso não é preciosismo: se ANTHROPIC_API_KEY
virar variável de ambiente do processo, o subprocesso do Claude Code a herda e
passa a cobrar pela API em vez de usar a assinatura do usuário — exatamente o
oposto do que o modo "subscription" existe para fazer.
"""

import os
from dotenv import dotenv_values

# Versão do Claybrick. Precisa bater com o VERSION do plugin
# (plugin/ClaudeStudio.luau) — o make-release.ps1 quebra a build se divergirem,
# e é a partir daqui que o site/version.json é gerado.
VERSION = "0.2.7"

_ENV_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".env")
CONFIG = dotenv_values(_ENV_PATH)

API_KEY = CONFIG.get("ANTHROPIC_API_KEY") or None
API_MODEL = CONFIG.get("CLAUDE_MODEL") or "claude-opus-4-8"
SUBSCRIPTION_MODEL = CONFIG.get("SUBSCRIPTION_MODEL") or None  # None = padrão do Claude Code
MAX_TOKENS = int(CONFIG.get("CLAUDE_MAX_TOKENS") or "32000")

# low | medium | high | xhigh | max. "high" equilibra qualidade e custo; "xhigh"
# é o melhor para trabalho de código/agêntico, e é o que mais rende aqui.
EFFORT = (CONFIG.get("CLAUDE_EFFORT") or "high").lower()

DEFAULT_BACKEND = (CONFIG.get("DEFAULT_BACKEND") or "api").lower()
POLL_TIMEOUT = float(CONFIG.get("POLL_TIMEOUT") or "20")
MAX_TURNS = int(CONFIG.get("MAX_TURNS") or "80")

# Com quantos tokens de entrada o servidor resume a conversa sozinho. A API
# recusa abaixo de 50.000, então o piso não é negociável. Mais baixo = compacta
# mais cedo e mais vezes (cada compactação é uma chamada extra ao modelo); mais
# alto = conversa mais longa em contexto, até o teto de 1M do Opus.
COMPACT_AT = max(50_000, int(CONFIG.get("COMPACT_AT") or "150000"))

# Generoso de propósito: o plugin pode estar esperando o usuário decidir uma
# permissão, e o relógio corre enquanto o card está aberto.
TOOL_TIMEOUT = float(CONFIG.get("TOOL_TIMEOUT") or "300")

HOST = CONFIG.get("HOST") or "127.0.0.1"

# 8787 e não 8000 de propósito: a 8000 é das portas mais disputadas do mundo
# (Django, python -m http.server, meio ecossistema web), e no Windows serviços do
# sistema chegam a segurá-la em 0.0.0.0 — o que faz o bind em 127.0.0.1 falhar
# com "acesso negado" em vez de "porta em uso". Se mudar aqui, mude junto o
# DEFAULT_URL do plugin: os dois lados precisam bater.
PORT = int(CONFIG.get("PORT") or "8787")
