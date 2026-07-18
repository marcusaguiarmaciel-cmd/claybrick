--!nonstrict
--[[
	Claude Studio — agente do Claude dentro do Roblox Studio
	=======================================================
	Chat no Studio ligado a um servidor-ponte local (Python) que fala com o
	Claude. Quando o Claude pede uma ferramenta, ela executa AQUI, no editor.

	PERMISSÕES
	Este plugin decide o que perguntar antes de executar; o servidor só carimba
	a classe de cada ferramenta (read/write/execute). Modos:
	  Perguntar        escritas e execuções pedem aprovação
	  Aceitar edições  escritas passam direto; execuções ainda perguntam
	  Sem permissões   tudo passa (bypass)
	Negar não trava o agente — vira um resultado de erro que ele lê e contorna.

	Instalação: .\install.ps1  (ou copie este arquivo para a pasta de Plugins)
	Requer o servidor-ponte rodando — veja o README.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local Selection = game:GetService("Selection")
local TweenService = game:GetService("TweenService")

-- ----------------------------------------------------------------------------
-- Configuração / persistência
-- ----------------------------------------------------------------------------
-- A ponte prefere a 8787, mas anda até a primeira porta livre desta faixa se ela
-- estiver ocupada (veja PORT_SPAN em server/app.py — os dois lados precisam
-- concordar). Como o plugin não lê arquivo do disco, ele não tem como ser
-- avisado da porta: ele varre a faixa e adota quem responder com a assinatura
-- do /health. É isso que faz o usuário não precisar configurar porta nenhuma.
--
-- Não é 8000 de propósito: aquela porta vive ocupada, e no Windows serviços do
-- sistema chegam a segurá-la de um jeito que o servidor nem sobe.
local PORT_BASE = 8787
local PORT_SPAN = 10
local DEFAULT_URL = ("http://127.0.0.1:%d"):format(PORT_BASE)

-- Tem que bater com o VERSION do servidor (server/agent/config.py). O
-- make-release.ps1 quebra a build se divergirem.
local VERSION = "0.2.2"
local VERSION_URL = "https://claybrick.online/version.json"

local serverUrl = plugin:GetSetting("serverUrl") or DEFAULT_URL

-- Declarada aqui porque o httpRequest (bem abaixo) precisa chamá-la para se
-- recuperar sozinho, mas o corpo dela só pode existir depois da UI, que ela
-- atualiza. Sem a declaração antecipada, o `function discoverServer()` lá
-- embaixo viraria um global e o httpRequest enxergaria nil.
local discoverServer
local backend = plugin:GetSetting("backend") or "api"      -- "api" | "subscription"
local permMode = plugin:GetSetting("permMode") or "ask"    -- "ask" | "acceptEdits" | "bypass"
local alwaysAllow = plugin:GetSetting("alwaysAllow") or {} -- [toolName] = true

local sessionId = HttpService:GenerateGUID(false)
local busy = false
local cancelRequested = false

local MEMORY_NAME = "ClaudeProjectMemory" -- StringValue em ServerStorage

-- ----------------------------------------------------------------------------
-- Caminhos
-- ----------------------------------------------------------------------------
local function resolvePath(path)
	if path == nil or path == "" or path == "game" then
		return game
	end
	local cur = game
	for seg in string.gmatch(path, "[^%.]+") do
		if seg == "game" then
			cur = game
		else
			local nxt = cur:FindFirstChild(seg)
			if not nxt and cur == game then
				local ok, svc = pcall(function()
					return game:GetService(seg)
				end)
				if ok then
					nxt = svc
				end
			end
			if not nxt then
				return nil, ("Não encontrei '%s' em '%s'"):format(seg, path)
			end
			cur = nxt
		end
	end
	return cur
end

local function mustResolve(path, label)
	local inst, err = resolvePath(path)
	if not inst then
		error((label or "Caminho") .. " inválido: " .. tostring(path) .. " — " .. tostring(err or ""))
	end
	return inst
end

-- ----------------------------------------------------------------------------
-- Conversão de valores
-- ----------------------------------------------------------------------------
local function encodeValue(v)
	local t = typeof(v)
	if t == "string" or t == "number" or t == "boolean" then
		return v
	elseif t == "nil" then
		return nil
	elseif t == "Vector3" then
		return { type = "Vector3", value = { x = v.X, y = v.Y, z = v.Z } }
	elseif t == "Vector2" then
		return { type = "Vector2", value = { x = v.X, y = v.Y } }
	elseif t == "Color3" then
		return {
			type = "Color3",
			value = { r = v.R, g = v.G, b = v.B },
			rgb = { math.floor(v.R * 255 + 0.5), math.floor(v.G * 255 + 0.5), math.floor(v.B * 255 + 0.5) },
		}
	elseif t == "EnumItem" then
		return tostring(v)
	elseif t == "Instance" then
		return { type = "Instance", path = v:GetFullName() }
	elseif t == "CFrame" then
		local p, rx, ry, rz = v.Position, v:ToOrientation()
		return {
			type = "CFrame",
			position = { x = p.X, y = p.Y, z = p.Z },
			orientation = { x = math.deg(rx), y = math.deg(ry), z = math.deg(rz) },
		}
	elseif t == "UDim2" then
		return { type = "UDim2", value = { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset } }
	elseif t == "UDim" then
		return { type = "UDim", value = { v.Scale, v.Offset } }
	elseif t == "NumberRange" then
		return { type = "NumberRange", value = { v.Min, v.Max } }
	elseif t == "Rect" then
		return { type = "Rect", value = { v.Min.X, v.Min.Y, v.Max.X, v.Max.Y } }
	elseif t == "BrickColor" then
		return tostring(v)
	end
	return tostring(v)
end

local function decodeValue(spec)
	if type(spec) ~= "table" then
		return spec
	end
	local t, v = spec.type, spec.value
	if t == nil then
		return spec
	elseif t == "Vector3" then
		return Vector3.new(v.x or v[1] or 0, v.y or v[2] or 0, v.z or v[3] or 0)
	elseif t == "Vector2" then
		return Vector2.new(v.x or v[1] or 0, v.y or v[2] or 0)
	elseif t == "Color3" then
		return Color3.new(v.r or v[1] or 0, v.g or v[2] or 0, v.b or v[3] or 0)
	elseif t == "Color3b" then
		return Color3.fromRGB(v.r or v[1] or 0, v.g or v[2] or 0, v.b or v[3] or 0)
	elseif t == "UDim2" then
		return UDim2.new(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0)
	elseif t == "UDim" then
		return UDim.new(v[1] or v.scale or 0, v[2] or v.offset or 0)
	elseif t == "NumberRange" then
		return NumberRange.new(v[1] or 0, v[2] or v[1] or 0)
	elseif t == "Rect" then
		return Rect.new(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0)
	elseif t == "Enum" then
		local s = tostring(v):gsub("^Enum%.", "")
		local en, item = s:match("([^%.]+)%.(.+)")
		if en and item then
			local ok, res = pcall(function()
				return Enum[en][item]
			end)
			if ok then
				return res
			end
		end
		error("Enum inválido: " .. tostring(v) .. " (use 'Material.Neon')")
	elseif t == "BrickColor" then
		return BrickColor.new(v)
	elseif t == "CFrame" then
		local p = v.position or v.pos or { x = 0, y = 0, z = 0 }
		local cf = CFrame.new(p.x or 0, p.y or 0, p.z or 0)
		if v.orientation then
			local o = v.orientation
			cf = cf * CFrame.fromOrientation(math.rad(o.x or 0), math.rad(o.y or 0), math.rad(o.z or 0))
		end
		return cf
	elseif t == "Instance" then
		return mustResolve(v, "Instância")
	end
	return v
end

local function applyProps(inst, props, failed)
	if not props then
		return
	end
	for k, v in pairs(props) do
		local ok, err = pcall(function()
			inst[k] = decodeValue(v)
		end)
		if not ok and failed then
			failed[k] = tostring(err)
		end
	end
end

-- ----------------------------------------------------------------------------
-- Código-fonte: ler/escrever respeitando o editor aberto
-- ----------------------------------------------------------------------------
local function readSource(inst)
	-- GetEditorSource enxerga edições ainda não salvas; .Source não.
	local ok, src = pcall(function()
		return ScriptEditorService:GetEditorSource(inst)
	end)
	if ok and type(src) == "string" then
		return src
	end
	return inst.Source
end

local function writeSource(inst, newText)
	-- Se o script está aberto no editor, escrever em .Source briga com o buffer
	-- do editor. EditTextAsync passa pelo editor e mantém tudo coerente.
	local okDoc, doc = pcall(function()
		return ScriptEditorService:FindScriptDocument(inst)
	end)
	if okDoc and doc then
		local lineCount = doc:GetLineCount()
		local lastLine = doc:GetLine(lineCount) or ""
		local ok, err = pcall(function()
			return doc:EditTextAsync(newText, 1, 1, lineCount, #lastLine + 1)
		end)
		if ok then
			return
		end
		warn("[Claude] EditTextAsync falhou, caindo para .Source: " .. tostring(err))
	end
	inst.Source = newText
end

-- ----------------------------------------------------------------------------
-- Undo
-- ----------------------------------------------------------------------------
local function recorded(label, fn)
	local rec = ChangeHistoryService:TryBeginRecording(label)
	local ok, res = pcall(fn)
	if rec then
		ChangeHistoryService:FinishRecording(
			rec,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		error(res, 0)
	end
	return res
end

-- ----------------------------------------------------------------------------
-- Ferramentas
-- ----------------------------------------------------------------------------
local Tools = {}

function Tools.get_tree(input)
	local root = mustResolve(input.path or "game", "Path")
	local maxDepth = input.max_depth or 3
	local MAX_NODES, count = 600, 0
	local function build(inst, depth)
		count += 1
		local node = { name = inst.Name, class = inst.ClassName, path = inst:GetFullName() }
		local kids = inst:GetChildren()
		if depth < maxDepth then
			local children = {}
			for _, child in ipairs(kids) do
				if count >= MAX_NODES then
					node.truncated = true
					break
				end
				table.insert(children, build(child, depth + 1))
			end
			if #children > 0 then
				node.children = children
			end
		elseif #kids > 0 then
			node.child_count = #kids
		end
		return node
	end
	return build(root, 0)
end

local function countUnder(service)
	local inst = game:FindFirstChild(service)
	if not inst then
		return nil
	end
	local total, scripts = 0, 0
	for _, d in ipairs(inst:GetDescendants()) do
		total += 1
		if d:IsA("LuaSourceContainer") then
			scripts += 1
		end
	end
	return { instances = total, scripts = scripts }
end

function Tools.get_place_info()
	local services = {}
	for _, name in ipairs({
		"Workspace", "ServerScriptService", "ServerStorage", "ReplicatedStorage",
		"StarterGui", "StarterPlayer", "Lighting", "SoundService",
	}) do
		services[name] = countUnder(name)
	end
	local memory = game:FindFirstChild("ServerStorage")
	memory = memory and memory:FindFirstChild(MEMORY_NAME)
	return {
		place_name = game.Name,
		place_id = game.PlaceId,
		game_id = game.GameId,
		is_running = RunService:IsRunning(),
		services = services,
		has_project_memory = memory ~= nil,
		capabilities = {
			run_code = loadstring ~= nil,
			script_editor = pcall(function()
				return ScriptEditorService:GetScriptDocuments()
			end),
			log_history = pcall(function()
				return LogService:GetLogHistory()
			end),
			playtest = RunService.Run ~= nil,
		},
	}
end

function Tools.get_selection()
	local out = {}
	for _, inst in ipairs(Selection:Get()) do
		table.insert(out, { path = inst:GetFullName(), class = inst.ClassName, name = inst.Name })
	end
	return { count = #out, selection = out }
end

function Tools.set_selection(input)
	local list = {}
	for _, p in ipairs(input.paths or {}) do
		local inst = resolvePath(p)
		if inst then
			table.insert(list, inst)
		end
	end
	Selection:Set(list)
	return { ok = true, selected = #list }
end

local DEFAULT_PROPS = {
	"Name", "ClassName", "Parent", "Anchored", "CanCollide", "Size", "Position",
	"Orientation", "CFrame", "Color", "Material", "Transparency", "Reflectance",
	"CastShadow", "Shape", "Text", "Value", "Enabled", "Disabled", "RunContext",
}

function Tools.get_properties(input)
	local inst = mustResolve(input.path)
	local props = {}
	for _, n in ipairs(input.names or DEFAULT_PROPS) do
		local ok, val = pcall(function()
			return inst[n]
		end)
		if ok then
			props[n] = encodeValue(val)
		end
	end
	local attrs = inst:GetAttributes()
	local hasAttrs = false
	for k, v in pairs(attrs) do
		attrs[k] = encodeValue(v)
		hasAttrs = true
	end
	return {
		path = inst:GetFullName(),
		properties = props,
		attributes = hasAttrs and attrs or nil,
		tags = #inst:GetTags() > 0 and inst:GetTags() or nil,
	}
end

function Tools.set_property(input)
	local inst = mustResolve(input.path)
	return recorded("Claude: " .. tostring(input.name), function()
		local ok, err = pcall(function()
			inst[input.name] = decodeValue(input.value)
		end)
		if not ok then
			error("Falha ao definir " .. tostring(input.name) .. ": " .. tostring(err), 0)
		end
		return { ok = true, path = inst:GetFullName(), property = input.name }
	end)
end

function Tools.find_instances(input)
	local ancestor = mustResolve(input.ancestor_path or "game", "Ancestor")
	local limit = input.limit or 100
	local wantName = input.name
	local contains = input.name_contains and input.name_contains:lower() or nil
	local results = {}
	for _, d in ipairs(ancestor:GetDescendants()) do
		local match = true
		if input.class_name then
			local ok, isa = pcall(function()
				return d:IsA(input.class_name)
			end)
			match = ok and isa
		end
		if match and wantName and d.Name ~= wantName then
			match = false
		end
		if match and contains and not d.Name:lower():find(contains, 1, true) then
			match = false
		end
		if match then
			table.insert(results, { path = d:GetFullName(), class = d.ClassName, name = d.Name })
			if #results >= limit then
				break
			end
		end
	end
	return { count = #results, matches = results }
end

function Tools.get_source(input)
	local inst = mustResolve(input.path)
	if not inst:IsA("LuaSourceContainer") then
		error(inst.ClassName .. " não é um script")
	end
	local src = readSource(inst)
	local lines = string.split(src, "\n")
	local first = math.max(1, input.start_line or 1)
	local last = math.min(#lines, input.end_line or #lines)
	local out = {}
	for i = first, last do
		table.insert(out, ("%4d | %s"):format(i, lines[i]))
	end
	return {
		path = inst:GetFullName(),
		class = inst.ClassName,
		total_lines = #lines,
		shown = ("%d-%d"):format(first, last),
		source = table.concat(out, "\n"),
	}
end

function Tools.search_source(input)
	local ancestor = mustResolve(input.ancestor_path or "game", "Ancestor")
	local pattern = input.pattern
	local maxResults = input.max_results or 50
	local hits, scanned = {}, 0
	for _, d in ipairs(ancestor:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then
			scanned += 1
			local okSrc, src = pcall(readSource, d)
			if okSrc then
				local n = 0
				for line in (src .. "\n"):gmatch("([^\n]*)\n") do
					n += 1
					local hay = input.ignore_case and line:lower() or line
					local needle = input.ignore_case and pattern:lower() or pattern
					local ok, found = pcall(string.find, hay, needle)
					if ok and found then
						table.insert(hits, {
							path = d:GetFullName(),
							line = n,
							text = line:sub(1, 200),
						})
						if #hits >= maxResults then
							return { count = #hits, scripts_scanned = scanned, truncated = true, matches = hits }
						end
					end
				end
			end
		end
	end
	return { count = #hits, scripts_scanned = scanned, matches = hits }
end

function Tools.check_syntax(input)
	local src = input.source
	local label = "código"
	if not src and input.path then
		local inst = mustResolve(input.path)
		if not inst:IsA("LuaSourceContainer") then
			error(inst.ClassName .. " não é um script")
		end
		src = readSource(inst)
		label = inst:GetFullName()
	end
	if not src then
		error("Passe 'source' ou 'path'.")
	end
	if not loadstring then
		return { ok = true, note = "loadstring indisponível — não deu para checar a sintaxe." }
	end
	local fn, err = loadstring(src, "check")
	if fn then
		return { ok = true, checked = label, lines = #string.split(src, "\n") }
	end
	return { ok = false, checked = label, error = tostring(err) }
end

function Tools.get_output(input)
	local ok, history = pcall(function()
		return LogService:GetLogHistory()
	end)
	if not ok then
		error("Não consegui ler o Output: " .. tostring(history))
	end
	local limit = input.limit or 50
	local out = {}
	-- Do mais recente para o mais antigo.
	for i = #history, 1, -1 do
		local entry = history[i]
		local kind = entry.messageType and entry.messageType.Name or "MessageOutput"
		local isProblem = kind == "MessageError" or kind == "MessageWarning"
		if not input.only_errors or isProblem then
			table.insert(out, {
				type = kind:gsub("^Message", ""),
				message = entry.message,
				timestamp = entry.timestamp,
			})
			if #out >= limit then
				break
			end
		end
	end
	return { count = #out, messages = out }
end

-- Memória de projeto: um StringValue em ServerStorage. Mora dentro do place, o
-- que é o ponto — sobrevive a reinícios e viaja junto com o arquivo.
local function memoryValue(createIfMissing)
	local storage = game:GetService("ServerStorage")
	local v = storage:FindFirstChild(MEMORY_NAME)
	if not v and createIfMissing then
		v = Instance.new("StringValue")
		v.Name = MEMORY_NAME
		v.Parent = storage
	end
	return v
end

function Tools.get_project_memory()
	local v = memoryValue(false)
	if not v then
		return {
			exists = false,
			note = "Nenhuma anotação ainda. Se decidir algo de arquitetura que não é "
				.. "óbvio pelo código, grave com set_project_memory.",
		}
	end
	return { exists = true, content = v.Value }
end

function Tools.set_project_memory(input)
	return recorded("Claude: memória do projeto", function()
		local v = memoryValue(true)
		v.Value = input.content or ""
		return { ok = true, path = v:GetFullName(), length = #v.Value }
	end)
end

function Tools.create_instance(input)
	local parent = mustResolve(input.parent_path or "Workspace", "Parent")
	return recorded("Claude: criar " .. tostring(input.class_name), function()
		local ok, inst = pcall(Instance.new, input.class_name)
		if not ok or not inst then
			error("Classe inválida: " .. tostring(input.class_name) .. " (confira com lookup_api)", 0)
		end
		if input.name then
			inst.Name = input.name
		end
		local failed = {}
		applyProps(inst, input.properties, failed)
		inst.Parent = parent -- por último: monta o objeto inteiro, depois pendura
		local res = { ok = true, path = inst:GetFullName(), class = inst.ClassName }
		if next(failed) then
			res.failed_properties = failed
		end
		return res
	end)
end

function Tools.delete_instance(input)
	local inst = mustResolve(input.path)
	local full = inst:GetFullName()
	return recorded("Claude: remover " .. inst.Name, function()
		inst.Parent = nil
		return { ok = true, removed = full }
	end)
end

function Tools.set_source(input)
	local inst = mustResolve(input.path)
	if not inst:IsA("LuaSourceContainer") then
		error(inst.ClassName .. " não é um script")
	end
	return recorded("Claude: editar " .. inst.Name, function()
		writeSource(inst, input.source or "")
		return { ok = true, path = inst:GetFullName(), length = #(input.source or "") }
	end)
end

function Tools.patch_source(input)
	local inst = mustResolve(input.path)
	if not inst:IsA("LuaSourceContainer") then
		error(inst.ClassName .. " não é um script")
	end
	local src = readSource(inst)
	local old, new = input.old_text, input.new_text

	-- Contagem literal (plain find), sem magia de pattern.
	local count, pos = 0, 1
	while true do
		local s = src:find(old, pos, true)
		if not s then
			break
		end
		count += 1
		pos = s + #old
	end

	if count == 0 then
		error(
			"old_text não aparece em " .. inst:GetFullName() .. ". O texto precisa bater "
				.. "LITERALMENTE, incluindo indentação. Releia com get_source.",
			0
		)
	end
	if count > 1 and not input.replace_all then
		error(
			("old_text aparece %d vezes em %s. Inclua mais contexto para deixar único, "):format(count, inst:GetFullName())
				.. "ou passe replace_all=true.",
			0
		)
	end

	return recorded("Claude: editar " .. inst.Name, function()
		local result
		if input.replace_all then
			local parts, p = {}, 1
			while true do
				local s = src:find(old, p, true)
				if not s then
					table.insert(parts, src:sub(p))
					break
				end
				table.insert(parts, src:sub(p, s - 1))
				table.insert(parts, new)
				p = s + #old
			end
			result = table.concat(parts)
		else
			local s = src:find(old, 1, true)
			result = src:sub(1, s - 1) .. new .. src:sub(s + #old)
		end
		writeSource(inst, result)
		return { ok = true, path = inst:GetFullName(), replaced = input.replace_all and count or 1 }
	end)
end

function Tools.move_instance(input)
	local inst = mustResolve(input.path)
	local parent = mustResolve(input.new_parent_path, "Parent")
	return recorded("Claude: mover " .. inst.Name, function()
		inst.Parent = parent
		return { ok = true, path = inst:GetFullName() }
	end)
end

function Tools.rename_instance(input)
	local inst = mustResolve(input.path)
	return recorded("Claude: renomear " .. inst.Name, function()
		inst.Name = input.new_name
		return { ok = true, path = inst:GetFullName() }
	end)
end

function Tools.clone_instance(input)
	local inst = mustResolve(input.path)
	local parent = input.parent_path and mustResolve(input.parent_path, "Parent") or inst.Parent
	local count = math.clamp(input.count or 1, 1, 200)
	return recorded("Claude: clonar " .. inst.Name, function()
		local made = {}
		for i = 1, count do
			local c = inst:Clone()
			if input.name then
				c.Name = count > 1 and (input.name .. i) or input.name
			end
			c.Parent = parent
			table.insert(made, c:GetFullName())
		end
		return { ok = true, count = #made, paths = made }
	end)
end

function Tools.set_attribute(input)
	local inst = mustResolve(input.path)
	return recorded("Claude: attribute " .. tostring(input.name), function()
		local v = input.value
		-- value nulo remove o attribute.
		inst:SetAttribute(input.name, if v == nil then nil else decodeValue(v))
		return { ok = true, path = inst:GetFullName(), attribute = input.name }
	end)
end

function Tools.set_tags(input)
	local inst = mustResolve(input.path)
	return recorded("Claude: tags de " .. inst.Name, function()
		for _, t in ipairs(input.add or {}) do
			CollectionService:AddTag(inst, t)
		end
		for _, t in ipairs(input.remove or {}) do
			CollectionService:RemoveTag(inst, t)
		end
		return { ok = true, path = inst:GetFullName(), tags = inst:GetTags() }
	end)
end

local function vec3(t, padrao)
	if type(t) ~= "table" then
		return padrao
	end
	return Vector3.new(t.x or 0, t.y or 0, t.z or 0)
end

local function cframeDe(pos, ori)
	local c = CFrame.new(vec3(pos, Vector3.zero))
	if type(ori) == "table" then
		c = c * CFrame.Angles(math.rad(ori.x or 0), math.rad(ori.y or 0), math.rad(ori.z or 0))
	end
	return c
end

function Tools.solid_op(input)
	local base = mustResolve(input.base_path, "base_path")
	if not base:IsA("BasePart") then
		error("base_path precisa ser uma peça (BasePart), e é um " .. base.ClassName, 0)
	end
	if type(input.parts) ~= "table" or #input.parts == 0 then
		error("parts precisa ter pelo menos um path.", 0)
	end

	local outras = {}
	for _, p in ipairs(input.parts) do
		local inst = mustResolve(p, "parts")
		if not inst:IsA("BasePart") then
			error("parts só aceita peças; '" .. p .. "' é um " .. inst.ClassName, 0)
		end
		table.insert(outras, inst)
	end

	local fidelity = Enum.CollisionFidelity.Default
	if input.collision_fidelity then
		local ok, e = pcall(function()
			return Enum.CollisionFidelity[input.collision_fidelity]
		end)
		if ok and e then
			fidelity = e
		end
	end

	local nome = input.name or base.Name
	local pai = base.Parent

	return recorded("Claude: " .. tostring(input.operation), function()
		local ok, res = pcall(function()
			if input.operation == "union" then
				return base:UnionAsync(outras, fidelity)
			elseif input.operation == "subtract" then
				return base:SubtractAsync(outras, fidelity)
			elseif input.operation == "intersect" then
				return base:IntersectAsync(outras, fidelity)
			end
			error("operation inválida: " .. tostring(input.operation), 0)
		end)
		if not ok or not res then
			error(
				"A operação falhou: " .. tostring(res) .. "\nCSG recusa peça sem volume, "
					.. "peça que não se toca, e às vezes geometria degenerada. Confira se as peças "
					.. "realmente se sobrepõem na posição atual.",
				0
			)
		end

		res.Name = nome
		res.Parent = pai
		base:Destroy()
		for _, o in ipairs(outras) do
			o:Destroy()
		end
		Selection:Set({ res })
		return ("%s: %s (%s). As peças de origem foram consumidas."):format(
			tostring(input.operation),
			res:GetFullName(),
			res.ClassName
		)
	end)
end

function Tools.terrain_fill(input)
	local terrain = workspace.Terrain
	if not terrain then
		error("Este place não tem Terrain.", 0)
	end

	local material
	local ok = pcall(function()
		material = Enum.Material[input.material]
	end)
	if not ok or not material then
		error("Material inválido: " .. tostring(input.material) .. " (use Grass, Rock, Water, Air...)", 0)
	end

	local c = cframeDe(input.position, input.orientation)

	return recorded("Claude: terreno " .. tostring(input.shape), function()
		if input.shape == "block" then
			terrain:FillBlock(c, vec3(input.size, Vector3.new(4, 4, 4)), material)
		elseif input.shape == "wedge" then
			terrain:FillWedge(c, vec3(input.size, Vector3.new(4, 4, 4)), material)
		elseif input.shape == "ball" then
			terrain:FillBall(c.Position, input.radius or 4, material)
		elseif input.shape == "cylinder" then
			terrain:FillCylinder(c, input.height or 4, input.radius or 4, material)
		else
			error("shape inválido: " .. tostring(input.shape), 0)
		end
		return ("terreno %s preenchido com %s em %s"):format(
			tostring(input.shape),
			input.material,
			tostring(c.Position)
		)
	end)
end

function Tools.insert_asset(input)
	local parent = mustResolve(input.parent_path or "Workspace", "Parent")
	return recorded("Claude: inserir asset " .. tostring(input.asset_id), function()
		local ok, model = pcall(function()
			return InsertService:LoadAsset(input.asset_id)
		end)
		if not ok then
			error("Não consegui carregar o asset " .. tostring(input.asset_id) .. ": " .. tostring(model), 0)
		end
		local made = {}
		for _, child in ipairs(model:GetChildren()) do
			child.Parent = parent
			table.insert(made, child:GetFullName())
		end
		model:Destroy()
		return { ok = true, inserted = made }
	end)
end

-- batch: várias escritas como UMA transação — um undo, uma permissão.
local OPS = {
	create_instance = true, delete_instance = true, set_property = true,
	set_source = true, patch_source = true, move_instance = true,
	rename_instance = true, clone_instance = true, set_attribute = true,
	set_tags = true,
}

function Tools.batch(input)
	local ops = input.ops or {}
	local stopOnError = input.stop_on_error ~= false
	local ids = {} -- "$meu_id" -> path criado

	-- Resolve referências "$id" para o path do que foi criado antes no lote.
	local function deref(v)
		if type(v) == "string" and v:sub(1, 1) == "$" then
			local resolved = ids[v]
			if not resolved then
				error("Referência desconhecida: " .. v .. " (defina 'id' numa op de create anterior)", 0)
			end
			return resolved
		end
		return v
	end

	return recorded("Claude: " .. (input.label or "lote"), function()
		local results = {}
		for i, op in ipairs(ops) do
			local name = op.op
			if not OPS[name] then
				local msg = ("op #%d inválida: '%s'. Válidas: %s"):format(
					i, tostring(name), table.concat({
						"create_instance", "delete_instance", "set_property", "set_source",
						"patch_source", "move_instance", "rename_instance", "clone_instance",
						"set_attribute", "set_tags",
					}, ", ")
				)
				if stopOnError then
					error(msg, 0)
				end
				table.insert(results, { index = i, ok = false, error = msg })
			else
				local args = {}
				for k, v in pairs(op) do
					if k ~= "op" and k ~= "id" then
						args[k] = deref(v)
					end
				end
				-- As ops do lote já estão sob um recording; chamar a ferramenta
				-- direto aninharia outro. Por isso `recorded` aceita aninhamento
				-- via TryBeginRecording devolvendo nil — o Studio junta tudo no
				-- waypoint de fora.
				local ok, res = pcall(Tools[name], args)
				if ok then
					if op.id and res and res.path then
						ids[op.id] = res.path
					end
					table.insert(results, { index = i, op = name, ok = true, path = res and res.path })
				else
					local msg = tostring(res)
					table.insert(results, { index = i, op = name, ok = false, error = msg })
					if stopOnError then
						error(("op #%d (%s) falhou: %s"):format(i, name, msg), 0)
					end
				end
			end
		end
		local failed = 0
		for _, r in ipairs(results) do
			if not r.ok then
				failed += 1
			end
		end
		return { ok = failed == 0, total = #results, failed = failed, results = results }
	end)
end

function Tools.run_code(input)
	if not loadstring then
		error("loadstring não está disponível neste Studio — run_code não funciona aqui.")
	end
	local fn, compileErr = loadstring(input.code or "", "ClaudeRunCode")
	if not fn then
		error("Erro de compilação: " .. tostring(compileErr), 0)
	end

	-- Captura print/warn substituindo-os no ambiente do chunk. Mais confiável
	-- que LogService.MessageOut, que já teve histórico de não disparar em plugin.
	local captured = {}
	local function grab(kind)
		return function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			table.insert(captured, kind .. table.concat(parts, " "))
		end
	end
	local env = setmetatable(
		{ print = grab(""), warn = grab("[warn] ") },
		{ __index = getfenv(0) }
	)
	setfenv(fn, env)

	local ok, res = pcall(function()
		return recorded("Claude: " .. (input.label or "run_code"), fn)
	end)

	local out = {
		ok = ok,
		output = #captured > 0 and table.concat(captured, "\n") or nil,
	}
	if ok then
		out.returned = (res ~= nil) and encodeValue(res) or nil
		if out.returned == nil and out.output == nil then
			out.note = "Rodou sem erro. Não houve return nem print."
		end
	else
		out.error = tostring(res)
	end
	return out
end

function Tools.run_playtest(input)
	if RunService:IsRunning() then
		error("Já há uma simulação rodando. Pare-a antes.")
	end
	local duration = math.clamp(input.duration or 3, 0.5, 30)
	local before = #LogService:GetLogHistory()

	RunService:Run()
	task.wait(duration)
	RunService:Stop()

	local out = {
		ok = true,
		ran_for = duration,
		warning = "A simulação NÃO foi revertida: Stop() não restaura o place. "
			.. "O que a física moveu e os scripts criaram continua aí.",
	}
	if input.capture_output ~= false then
		local history = LogService:GetLogHistory()
		local logs = {}
		for i = before + 1, #history do
			local e = history[i]
			table.insert(logs, {
				type = (e.messageType and e.messageType.Name or "MessageOutput"):gsub("^Message", ""),
				message = e.message,
			})
		end
		out.output = logs
		out.output_count = #logs
	end
	return out
end

local function executeTool(name, input)
	local fn = Tools[name]
	if not fn then
		error("Ferramenta desconhecida: " .. tostring(name))
	end
	local result = fn(input or {})
	if type(result) == "table" then
		return HttpService:JSONEncode(result)
	end
	return tostring(result)
end

-- ----------------------------------------------------------------------------
-- HTTP
-- ----------------------------------------------------------------------------
local function httpRequest(method, path, body, retried)
	local opts = {
		Url = serverUrl .. path,
		Method = method,
		Headers = { ["Content-Type"] = "application/json" },
	}
	if body ~= nil then
		opts.Body = HttpService:JSONEncode(body)
	end
	local ok, response = pcall(function()
		return HttpService:RequestAsync(opts)
	end)
	if not ok then
		-- Não deu conexão. O caso comum não é "o servidor está desligado", e sim
		-- "o servidor subiu numa porta diferente porque a preferida estava
		-- ocupada". Procurar antes de acusar é o que faz isso se resolver
		-- sozinho. O `retried` corta a recursão: só uma varredura por chamada.
		if not retried and discoverServer and discoverServer() then
			return httpRequest(method, path, body, true)
		end
		return nil, "Sem conexão com " .. serverUrl .. ". O servidor está rodando? " .. tostring(response)
	end
	if not response.Success then
		local detail = response.Body
		local okd, decoded = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if okd and type(decoded) == "table" and decoded.detail then
			detail = decoded.detail
		end
		return nil, ("HTTP %s: %s"):format(tostring(response.StatusCode), tostring(detail))
	end
	if response.Body == nil or response.Body == "" then
		return {}
	end
	local okd, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not okd then
		return nil, "Resposta inválida do servidor"
	end
	return decoded
end

local function postJSON(path, body)
	return httpRequest("POST", path, body)
end
local function getJSON(path)
	return httpRequest("GET", path, nil)
end

-- ----------------------------------------------------------------------------
-- Interface
-- ----------------------------------------------------------------------------
-- Mesma paleta do claybrick.online. O plugin e o site são o mesmo produto; cinza
-- genérico aqui e identidade lá fazia parecer que não eram.
local COLORS = {
	bg = Color3.fromRGB(10, 12, 16),
	panel = Color3.fromRGB(20, 23, 31),
	user = Color3.fromRGB(24, 46, 74),
	assistant = Color3.fromRGB(28, 32, 43),
	system = Color3.fromRGB(58, 30, 26),
	permission = Color3.fromRGB(46, 38, 24),
	text = Color3.fromRGB(232, 230, 227),
	subtle = Color3.fromRGB(139, 143, 154),
	accent = Color3.fromRGB(255, 85, 53),
	danger = Color3.fromRGB(255, 85, 53),
	warn = Color3.fromRGB(210, 160, 70),
	border = Color3.fromRGB(38, 42, 53),
}

local MODE_LABEL = {
	ask = "Perguntar",
	acceptEdits = "Aceitar edições",
	bypass = "Sem permissões",
}
local MODE_COLOR = {
	ask = COLORS.accent,
	acceptEdits = COLORS.warn,
	bypass = COLORS.danger,
}
local MODE_ORDER = { "ask", "acceptEdits", "bypass" }

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 460, 700, 340, 440)
local widget = plugin:CreateDockWidgetPluginGui("ClaudeStudioChat", widgetInfo)
widget.Title = "Claude"
widget.Name = "ClaudeStudioChat"

local root = Instance.new("Frame")
root.Size = UDim2.new(1, 0, 1, 0)
root.BackgroundColor3 = COLORS.bg
root.BorderSizePixel = 0
root.Parent = widget

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 34)
header.BackgroundColor3 = COLORS.panel
header.BorderSizePixel = 0
header.Parent = root

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 10, 0, 0)
title.Size = UDim2.new(0, 60, 1, 0)
title.Font = Enum.Font.GothamMedium
title.TextSize = 14
title.TextColor3 = COLORS.text
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "Claude"
title.Parent = header

local function headerButton(text, xOffset, width)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, width or 30, 0, 24)
	b.Position = UDim2.new(1, xOffset, 0, 5)
	b.BackgroundColor3 = COLORS.assistant
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 15
	b.TextColor3 = COLORS.text
	b.Text = text
	b.AutoButtonColor = true
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 5)
	c.Parent = b
	b.Parent = header
	return b
end

local newChatBtn = headerButton("＋", -40)
local gearBtn = headerButton("⚙", -74)
local backendBtn = headerButton("API", -168, 88)
backendBtn.Font = Enum.Font.Gotham
backendBtn.TextSize = 12
local modeBtn = headerButton("Perguntar", -288, 116)
modeBtn.Font = Enum.Font.GothamMedium
modeBtn.TextSize = 12

-- Painel de configurações
local settings = Instance.new("Frame")
settings.Size = UDim2.new(1, 0, 0, 92)
settings.Position = UDim2.new(0, 0, 0, 34)
settings.BackgroundColor3 = COLORS.panel
settings.BorderSizePixel = 0
settings.Visible = false
settings.ZIndex = 5
settings.Parent = root

local urlLabel = Instance.new("TextLabel")
urlLabel.BackgroundTransparency = 1
urlLabel.Position = UDim2.new(0, 10, 0, 6)
urlLabel.Size = UDim2.new(1, -20, 0, 16)
urlLabel.Font = Enum.Font.Gotham
urlLabel.TextSize = 12
urlLabel.TextColor3 = COLORS.subtle
urlLabel.TextXAlignment = Enum.TextXAlignment.Left
urlLabel.Text = "URL do servidor-ponte:"
urlLabel.ZIndex = 5
urlLabel.Parent = settings

local urlBox = Instance.new("TextBox")
urlBox.Position = UDim2.new(0, 10, 0, 26)
urlBox.Size = UDim2.new(1, -90, 0, 26)
urlBox.BackgroundColor3 = COLORS.bg
urlBox.BorderSizePixel = 0
urlBox.Font = Enum.Font.Code
urlBox.TextSize = 13
urlBox.TextColor3 = COLORS.text
urlBox.TextXAlignment = Enum.TextXAlignment.Left
urlBox.ClearTextOnFocus = false
urlBox.Text = serverUrl
urlBox.ZIndex = 5
local urlPad = Instance.new("UIPadding")
urlPad.PaddingLeft = UDim.new(0, 6)
urlPad.Parent = urlBox
local urlCorner = Instance.new("UICorner")
urlCorner.CornerRadius = UDim.new(0, 5)
urlCorner.Parent = urlBox
urlBox.Parent = settings

-- ----------------------------------------------------------------------------
-- Descoberta do servidor
-- ----------------------------------------------------------------------------
-- Preenche o `discoverServer` declarado lá em cima. Só aqui embaixo porque
-- mexe na urlBox, que só existe a partir desta altura do arquivo.

-- Uma porta só responde "sim, sou a ponte" se devolver a assinatura do /health.
-- Sem conferir isso, o plugin poderia grudar em qualquer outro servidor local
-- escutando na faixa e falhar depois, de um jeito bem mais confuso.
local function isBridgeAt(url)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({ Url = url .. "/health", Method = "GET" })
	end)
	if not ok or not response.Success then
		return false
	end
	local okd, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	return okd and type(decoded) == "table" and decoded.service == "claybrick"
end

local function useServerUrl(url)
	serverUrl = url
	urlBox.Text = url
	plugin:SetSetting("serverUrl", url)
end

-- Devolve true se estamos apontando para uma ponte viva.
function discoverServer()
	-- A URL atual primeiro: no caso normal ela está certa, e aí é uma requisição
	-- só. Isso também respeita quem digitou uma URL própria na caixa.
	if isBridgeAt(serverUrl) then
		return true
	end
	for i = 0, PORT_SPAN - 1 do
		local candidate = ("http://127.0.0.1:%d"):format(PORT_BASE + i)
		if candidate ~= serverUrl and isBridgeAt(candidate) then
			useServerUrl(candidate)
			return true
		end
	end
	return false
end

local saveBtn = Instance.new("TextButton")
saveBtn.Position = UDim2.new(1, -74, 0, 26)
saveBtn.Size = UDim2.new(0, 64, 0, 26)
saveBtn.BackgroundColor3 = COLORS.user
saveBtn.BorderSizePixel = 0
saveBtn.Font = Enum.Font.GothamMedium
saveBtn.TextSize = 13
saveBtn.TextColor3 = COLORS.text
saveBtn.Text = "Salvar"
saveBtn.ZIndex = 5
local saveCorner = Instance.new("UICorner")
saveCorner.CornerRadius = UDim.new(0, 5)
saveCorner.Parent = saveBtn
saveBtn.Parent = settings

local forgetBtn = Instance.new("TextButton")
forgetBtn.Position = UDim2.new(0, 10, 0, 58)
forgetBtn.Size = UDim2.new(0, 240, 0, 26)
forgetBtn.BackgroundColor3 = COLORS.assistant
forgetBtn.BorderSizePixel = 0
forgetBtn.Font = Enum.Font.Gotham
forgetBtn.TextSize = 12
forgetBtn.TextColor3 = COLORS.text
forgetBtn.Text = "Esquecer \"permitir sempre\""
forgetBtn.ZIndex = 5
local forgetCorner = Instance.new("UICorner")
forgetCorner.CornerRadius = UDim.new(0, 5)
forgetCorner.Parent = forgetBtn
forgetBtn.Parent = settings

-- Lista de mensagens
-- ----------------------------------------------------------------------------
-- Barra de atualização
-- ----------------------------------------------------------------------------
-- Fica escondida até haver o que dizer. O Studio lê a pasta de plugins só no
-- boot (o hot reload dele existe mas vem desligado), então nem o instalador nem
-- o servidor conseguem trocar o plugin que já está rodando: avisar é o máximo
-- que dá para fazer sem mentir para o usuário.
local UPDATE_BAR_H = 30

local updateBar = Instance.new("TextButton")
updateBar.Size = UDim2.new(1, 0, 0, UPDATE_BAR_H)
updateBar.Position = UDim2.new(0, 0, 0, 34)
updateBar.BackgroundColor3 = COLORS.warn
updateBar.BorderSizePixel = 0
updateBar.Font = Enum.Font.GothamMedium
updateBar.TextSize = 12
updateBar.TextColor3 = COLORS.bg
updateBar.Text = ""
updateBar.AutoButtonColor = true
updateBar.Visible = false
updateBar.ZIndex = 3
updateBar.Parent = root

local scroll = Instance.new("ScrollingFrame")
scroll.Position = UDim2.new(0, 0, 0, 34)
scroll.Size = UDim2.new(1, 0, 1, -34 - 78)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 6
scroll.ScrollBarImageColor3 = COLORS.subtle
scroll.CanvasSize = UDim2.new()
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.ScrollingDirection = Enum.ScrollingDirection.Y
scroll.Parent = root

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 8)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
listLayout.Parent = scroll

local scrollPad = Instance.new("UIPadding")
scrollPad.PaddingTop = UDim.new(0, 10)
scrollPad.PaddingBottom = UDim.new(0, 10)
scrollPad.PaddingLeft = UDim.new(0, 8)
scrollPad.PaddingRight = UDim.new(0, 8)
scrollPad.Parent = scroll

-- Área de entrada
local inputArea = Instance.new("Frame")
inputArea.Position = UDim2.new(0, 0, 1, -78)
inputArea.Size = UDim2.new(1, 0, 0, 78)
inputArea.BackgroundColor3 = COLORS.panel
inputArea.BorderSizePixel = 0
inputArea.Parent = root

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.new(0, 12, 0, 2)
statusLabel.Size = UDim2.new(1, -100, 0, 14)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 11
statusLabel.TextColor3 = COLORS.accent
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Text = ""
statusLabel.Parent = inputArea

local cancelBtn = Instance.new("TextButton")
cancelBtn.Position = UDim2.new(1, -78, 0, 0)
cancelBtn.Size = UDim2.new(0, 68, 0, 16)
cancelBtn.BackgroundTransparency = 1
cancelBtn.Font = Enum.Font.Gotham
cancelBtn.TextSize = 11
cancelBtn.TextColor3 = COLORS.danger
cancelBtn.Text = "✕ Cancelar"
cancelBtn.Visible = false
cancelBtn.Parent = inputArea

local inputBox = Instance.new("TextBox")
inputBox.Position = UDim2.new(0, 10, 0, 18)
inputBox.Size = UDim2.new(1, -90, 1, -28)
inputBox.BackgroundColor3 = COLORS.bg
inputBox.BorderSizePixel = 0
inputBox.Font = Enum.Font.Gotham
inputBox.TextSize = 14
inputBox.TextColor3 = COLORS.text
inputBox.TextXAlignment = Enum.TextXAlignment.Left
inputBox.TextYAlignment = Enum.TextYAlignment.Top
inputBox.TextWrapped = true
inputBox.MultiLine = true
inputBox.ClearTextOnFocus = false
inputBox.PlaceholderText = "Peça algo ao Claude...  (ex: crie um sistema de moedas colecionáveis)"
inputBox.Text = ""
local inPad = Instance.new("UIPadding")
inPad.PaddingLeft = UDim.new(0, 8)
inPad.PaddingTop = UDim.new(0, 6)
inPad.PaddingRight = UDim.new(0, 8)
inPad.Parent = inputBox
local inCorner = Instance.new("UICorner")
inCorner.CornerRadius = UDim.new(0, 6)
inCorner.Parent = inputBox
inputBox.Parent = inputArea

local sendBtn = Instance.new("TextButton")
sendBtn.Position = UDim2.new(1, -74, 0, 18)
sendBtn.Size = UDim2.new(0, 64, 1, -28)
sendBtn.BackgroundColor3 = COLORS.user
sendBtn.BorderSizePixel = 0
sendBtn.Font = Enum.Font.GothamMedium
sendBtn.TextSize = 14
sendBtn.TextColor3 = COLORS.text
sendBtn.Text = "Enviar"
local sendCorner = Instance.new("UICorner")
sendCorner.CornerRadius = UDim.new(0, 6)
sendCorner.Parent = sendBtn
sendBtn.Parent = inputArea

-- Helpers de UI --------------------------------------------------------------
local layoutOrder = 0
local function nextOrder()
	layoutOrder += 1
	return layoutOrder
end

local function tween(obj, props, tempo, estilo)
	local t = TweenService:Create(
		obj,
		TweenInfo.new(tempo or 0.18, estilo or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

-- Se a pessoa subiu para reler algo, arrastar ela de volta pro fim a cada chunk
-- é hostil. Só acompanha quem já estava acompanhando.
local function estaNoFim()
	local sobra = scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y
	return sobra <= 0 or scroll.CanvasPosition.Y >= sobra - 48
end

local tweenScroll = nil
local function autoscroll(forcar)
	local grudado = forcar or estaNoFim()
	task.defer(function()
		if not grudado then
			return
		end
		local alvo = Vector2.new(0, math.max(0, scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteWindowSize.Y))
		if tweenScroll then
			tweenScroll:Cancel()
		end
		tweenScroll = tween(scroll, { CanvasPosition = alvo }, 0.22)
	end)
end

local function makeBubble(role)
	local container = Instance.new("Frame")
	container.Size = UDim2.new(1, -8, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.BackgroundColor3 = COLORS[role] or COLORS.assistant
	container.BorderSizePixel = 0
	container.LayoutOrder = nextOrder()
	container.BackgroundTransparency = 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = container

	local stroke = Instance.new("UIStroke")
	stroke.Color = COLORS.border
	stroke.Thickness = 1
	stroke.Transparency = 1
	stroke.Parent = container

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 22)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = container

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.Font = Enum.Font.Gotham
	label.TextSize = 14
	label.TextColor3 = COLORS.text
	label.TextTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.Text = ""
	label.Parent = container
	container.Parent = scroll

	-- Entrada: fade + um deslize curto. O deslize é feito pelo padding porque a
	-- posição de quem vive num UIListLayout é do layout, não nossa.
	tween(container, { BackgroundTransparency = 0 }, 0.22)
	tween(label, { TextTransparency = 0 }, 0.28)
	tween(stroke, { Transparency = 0.4 }, 0.3)
	tween(pad, { PaddingLeft = UDim.new(0, 10) }, 0.26, Enum.EasingStyle.Quint)

	return container, label
end

local function addBubble(role, text)
	local _, label = makeBubble(role)
	label.Text = text
	autoscroll()
end

-- Bolhas de streaming: texto e raciocínio chegam em pedaços.
local streamLabel, thinkLabel = nil, nil

local function appendText(chunk)
	if not streamLabel then
		local _, label = makeBubble("assistant")
		streamLabel = label
	end
	streamLabel.Text ..= chunk
	autoscroll()
end

local function appendThinking(chunk)
	if not thinkLabel then
		local container, label = makeBubble("assistant")
		container.BackgroundColor3 = COLORS.panel

		local cabecalho = Instance.new("TextLabel")
		cabecalho.BackgroundTransparency = 1
		cabecalho.Size = UDim2.new(1, 0, 0, 14)
		cabecalho.Font = Enum.Font.Code
		cabecalho.TextSize = 11
		cabecalho.TextColor3 = COLORS.accent
		cabecalho.TextXAlignment = Enum.TextXAlignment.Left
		cabecalho.Text = "● pensando"
		cabecalho.LayoutOrder = 0
		cabecalho.Parent = container

		-- Pulsa enquanto o raciocínio chega. Para sozinho quando a bolha morre.
		task.spawn(function()
			while cabecalho.Parent do
				tween(cabecalho, { TextTransparency = 0.65 }, 0.7, Enum.EasingStyle.Sine)
				task.wait(0.7)
				tween(cabecalho, { TextTransparency = 0 }, 0.7, Enum.EasingStyle.Sine)
				task.wait(0.7)
			end
		end)

		local lista = Instance.new("UIListLayout")
		lista.SortOrder = Enum.SortOrder.LayoutOrder
		lista.Padding = UDim.new(0, 6)
		lista.Parent = container

		label.LayoutOrder = 1
		label.Font = Enum.Font.GothamItalic
		label.TextSize = 12
		label.TextColor3 = COLORS.subtle
		thinkLabel = label
	end
	thinkLabel.Text ..= chunk
	autoscroll()
end

local function endStream()
	streamLabel, thinkLabel = nil, nil
end

local function summarize(name, input)
	local ok, s = pcall(function()
		return HttpService:JSONEncode(input)
	end)
	s = ok and s or "{}"
	if #s > 120 then
		s = s:sub(1, 117) .. "..."
	end
	return name .. "  " .. s
end

local function addToolLine(name, input, success)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -8, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextColor3 = success and COLORS.accent or COLORS.danger
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.Text = (success and "🔧 " or "⚠️ ") .. summarize(name, input)
	label.LayoutOrder = nextOrder()
	label.Parent = scroll
	autoscroll()
end

local function setStatus(text)
	statusLabel.Text = text or ""
end

local function clearChat()
	for _, child in ipairs(scroll:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	layoutOrder = 0
	endStream()
end

-- ----------------------------------------------------------------------------
-- Permissões
-- ----------------------------------------------------------------------------
local PERM_EXPLAIN = {
	write = "vai modificar o place (desfazível com Ctrl+Z)",
	execute = "vai EXECUTAR código no Studio — nem tudo é desfazível",
}

local function needsPermission(perm)
	if perm == "read" then
		return false
	end
	if permMode == "bypass" then
		return false
	end
	if permMode == "acceptEdits" and perm == "write" then
		return false
	end
	return true
end

-- Card de aprovação. Bloqueia até o usuário decidir; devolve
-- "allow" | "always" | "deny", e o motivo quando negado.
local function askPermission(name, input, perm)
	local container = Instance.new("Frame")
	container.Size = UDim2.new(1, -8, 0, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.BackgroundColor3 = COLORS.permission
	container.BorderSizePixel = 0
	container.LayoutOrder = nextOrder()
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = container
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = container
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = container

	local head = Instance.new("TextLabel")
	head.BackgroundTransparency = 1
	head.Size = UDim2.new(1, 0, 0, 0)
	head.AutomaticSize = Enum.AutomaticSize.Y
	head.Font = Enum.Font.GothamMedium
	head.TextSize = 13
	head.TextColor3 = perm == "execute" and COLORS.danger or COLORS.warn
	head.TextXAlignment = Enum.TextXAlignment.Left
	head.TextWrapped = true
	head.Text = "Permitir?  " .. name .. "\n" .. (PERM_EXPLAIN[perm] or "")
	head.LayoutOrder = 1
	head.Parent = container

	local detail = Instance.new("TextLabel")
	detail.BackgroundTransparency = 1
	detail.Size = UDim2.new(1, 0, 0, 0)
	detail.AutomaticSize = Enum.AutomaticSize.Y
	detail.Font = Enum.Font.Code
	detail.TextSize = 11
	detail.TextColor3 = COLORS.text
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextWrapped = true
	local ok, pretty = pcall(function()
		return HttpService:JSONEncode(input)
	end)
	pretty = ok and pretty or "{}"
	if #pretty > 600 then
		pretty = pretty:sub(1, 597) .. "..."
	end
	detail.Text = pretty
	detail.LayoutOrder = 2
	detail.Parent = container

	local reasonBox = Instance.new("TextBox")
	reasonBox.Size = UDim2.new(1, 0, 0, 24)
	reasonBox.BackgroundColor3 = COLORS.bg
	reasonBox.BorderSizePixel = 0
	reasonBox.Font = Enum.Font.Gotham
	reasonBox.TextSize = 12
	reasonBox.TextColor3 = COLORS.text
	reasonBox.TextXAlignment = Enum.TextXAlignment.Left
	reasonBox.ClearTextOnFocus = false
	reasonBox.PlaceholderText = "Motivo, se negar (o Claude lê e se adapta)"
	reasonBox.Text = ""
	reasonBox.LayoutOrder = 3
	local rPad = Instance.new("UIPadding")
	rPad.PaddingLeft = UDim.new(0, 6)
	rPad.Parent = reasonBox
	local rCorner = Instance.new("UICorner")
	rCorner.CornerRadius = UDim.new(0, 4)
	rCorner.Parent = reasonBox
	reasonBox.Parent = container

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 26)
	row.BackgroundTransparency = 1
	row.LayoutOrder = 4
	row.Parent = container
	local rowList = Instance.new("UIListLayout")
	rowList.FillDirection = Enum.FillDirection.Horizontal
	rowList.Padding = UDim.new(0, 6)
	rowList.Parent = row

	local decision = nil
	local function mkBtn(text, color, width, value)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, width, 1, 0)
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 12
		b.TextColor3 = COLORS.text
		b.Text = text
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 4)
		c.Parent = b
		b.Parent = row
		b.Activated:Connect(function()
			decision = value
		end)
		return b
	end

	mkBtn("Permitir", COLORS.accent, 80, "allow")
	mkBtn("Permitir sempre", COLORS.assistant, 116, "always")
	mkBtn("Negar", COLORS.danger, 64, "deny")

	container.Parent = scroll
	autoscroll()
	setStatus("Esperando sua permissão...")

	while decision == nil do
		if cancelRequested then
			decision = "deny"
			reasonBox.Text = "Usuário cancelou o turno."
			break
		end
		task.wait(0.1)
	end

	local reason = reasonBox.Text
	-- Colapsa o card no resultado, para o chat não virar um mural de botões.
	local verdict = ({ allow = "permitido", always = "permitido sempre", deny = "NEGADO" })[decision]
	container:ClearAllChildren()
	pad.Parent = container
	local done = Instance.new("TextLabel")
	done.BackgroundTransparency = 1
	done.Size = UDim2.new(1, 0, 0, 0)
	done.AutomaticSize = Enum.AutomaticSize.Y
	done.Font = Enum.Font.Gotham
	done.TextSize = 12
	done.TextColor3 = decision == "deny" and COLORS.danger or COLORS.accent
	done.TextXAlignment = Enum.TextXAlignment.Left
	done.TextWrapped = true
	done.Text = ("%s — %s%s"):format(name, verdict, (reason ~= "" and decision == "deny") and (": " .. reason) or "")
	done.Parent = container

	return decision, reason
end

-- ----------------------------------------------------------------------------
-- Contexto do place (injetado no começo da sessão)
-- ----------------------------------------------------------------------------
local function placeContext()
	local ok, info = pcall(Tools.get_place_info)
	if not ok then
		return nil
	end
	local lines = { ("Place: %s (PlaceId %s)"):format(tostring(info.place_name), tostring(info.place_id)) }
	for _, name in ipairs({
		"Workspace", "ServerScriptService", "ServerStorage", "ReplicatedStorage",
		"StarterGui", "StarterPlayer", "Lighting",
	}) do
		local s = info.services[name]
		if s then
			table.insert(lines, ("  %s: %d instâncias, %d scripts"):format(name, s.instances, s.scripts))
		end
	end
	if info.has_project_memory then
		table.insert(lines, "Há anotações suas de sessões anteriores — leia com get_project_memory.")
	end
	local caps = {}
	for k, v in pairs(info.capabilities) do
		if not v then
			table.insert(caps, k)
		end
	end
	if #caps > 0 then
		table.insert(lines, "Capacidades INDISPONÍVEIS neste Studio: " .. table.concat(caps, ", "))
	end
	return table.concat(lines, "\n")
end

local contextSent = false

-- ----------------------------------------------------------------------------
-- Laço do agente
-- ----------------------------------------------------------------------------
local function handleToolJob(ev)
	local perm = ev.permission or "execute"
	local name = ev.name

	if needsPermission(perm) and not alwaysAllow[name] then
		local decision, reason = askPermission(name, ev.input, perm)
		if decision == "always" then
			alwaysAllow[name] = true
			plugin:SetSetting("alwaysAllow", alwaysAllow)
		elseif decision == "deny" then
			local msg = "PERMISSÃO NEGADA pelo usuário para '" .. name .. "'."
			if reason ~= "" then
				msg ..= " Motivo: " .. reason .. "."
			end
			msg ..= " Não repita esta chamada — ela será negada de novo. Reveja o motivo,"
				.. " proponha outro caminho ou pergunte ao usuário."
			postJSON("/session/tool_result", {
				session_id = sessionId,
				id = ev.id,
				content = msg,
				is_error = true,
			})
			return
		end
	end

	setStatus("Trabalhando: " .. name)
	local okx, output = pcall(executeTool, name, ev.input)
	addToolLine(name, ev.input, okx)
	postJSON("/session/tool_result", {
		session_id = sessionId,
		id = ev.id,
		content = okx and output or tostring(output),
		is_error = not okx,
	})
end

local function runAgent(userText)
	addBubble("user", userText)
	setStatus("Pensando...")
	cancelBtn.Visible = true

	local ctx = nil
	if not contextSent then
		ctx = placeContext()
		contextSent = true
	end

	local ok, err = postJSON("/session/message", {
		session_id = sessionId,
		message = userText,
		backend = backend,
		place_context = ctx,
	})
	if not ok then
		addBubble("system", "Erro: " .. tostring(err))
		setStatus("")
		cancelBtn.Visible = false
		return
	end

	local finished, guard = false, 0
	while not finished and guard < 20000 do
		guard += 1
		local ev, perr = getJSON("/session/poll?session_id=" .. sessionId)
		if not ev then
			addBubble("system", "Erro de conexão: " .. tostring(perr))
			break
		end
		local t = ev.type
		if t == "tool" then
			endStream()
			handleToolJob(ev)
			setStatus("Pensando...")
		elseif t == "text" then
			appendText(ev.text or "")
		elseif t == "thinking" then
			appendThinking(ev.text or "")
		elseif t == "message" then -- backend assinatura entrega o texto inteiro
			endStream()
			if ev.text and ev.text ~= "" then
				addBubble("assistant", ev.text)
			end
		elseif t == "compaction" then
			endStream()
			addBubble("system", "A conversa ficou longa e foi resumida. O Claude segue com o resumo no lugar do começo dela.")
		elseif t == "usage" then
			local cached = (ev.cache_read or 0) > 0 and (" · cache %d"):format(ev.cache_read) or ""
			setStatus(("%d in · %d out%s"):format(ev.input or 0, ev.output or 0, cached))
		elseif t == "error" then
			endStream()
			addBubble("system", ev.message or "Erro desconhecido")
		elseif t == "done" or t == "idle" then
			finished = true
		end
		-- "wait": long-poll expirou sem eventos; continua.
	end
	endStream()
	cancelBtn.Visible = false
end

local function send()
	if busy then
		return
	end
	local text = inputBox.Text
	if text:gsub("%s", "") == "" then
		return
	end
	inputBox.Text = ""
	busy = true
	cancelRequested = false
	sendBtn.Text = "..."
	task.spawn(function()
		local ok, e = pcall(runAgent, text)
		if not ok then
			addBubble("system", "Erro interno do plugin: " .. tostring(e))
		end
		setStatus("")
		cancelBtn.Visible = false
		busy = false
		sendBtn.Text = "Enviar"
	end)
end

local function newChat()
	if busy then
		return
	end
	pcall(postJSON, "/session/reset", { session_id = sessionId })
	sessionId = HttpService:GenerateGUID(false)
	contextSent = false
	clearChat()
	addBubble("assistant", "Chat novo. O que vamos construir?")
end

local function updateHeader()
	backendBtn.Text = backend == "subscription" and "Assinatura" or "API"
	modeBtn.Text = MODE_LABEL[permMode]
	modeBtn.TextColor3 = MODE_COLOR[permMode]
end

-- Eventos --------------------------------------------------------------------
sendBtn.Activated:Connect(send)
newChatBtn.Activated:Connect(newChat)
gearBtn.Activated:Connect(function()
	settings.Visible = not settings.Visible
end)

cancelBtn.Activated:Connect(function()
	cancelRequested = true
	setStatus("Cancelando...")
	pcall(postJSON, "/session/cancel", { session_id = sessionId })
end)

modeBtn.Activated:Connect(function()
	local i = table.find(MODE_ORDER, permMode) or 1
	permMode = MODE_ORDER[(i % #MODE_ORDER) + 1]
	plugin:SetSetting("permMode", permMode)
	updateHeader()
	if permMode == "bypass" then
		addBubble("system", "Modo SEM PERMISSÕES: o Claude executa tudo sem perguntar, "
			.. "inclusive run_code e playtest. Ctrl+Z desfaz as edições, mas não tudo.")
	else
		addBubble("system", "Modo: " .. MODE_LABEL[permMode])
	end
end)

backendBtn.Activated:Connect(function()
	if busy then
		return
	end
	backend = (backend == "api") and "subscription" or "api"
	plugin:SetSetting("backend", backend)
	updateHeader()
	newChat()
	addBubble("system", "Backend: " .. (backend == "subscription" and "Assinatura (Claude Code)" or "API (por token)"))
end)

saveBtn.Activated:Connect(function()
	local u = urlBox.Text:gsub("%s", "")
	if u:sub(-1) == "/" then
		u = u:sub(1, -2)
	end
	serverUrl = (u == "") and DEFAULT_URL or u
	urlBox.Text = serverUrl
	plugin:SetSetting("serverUrl", serverUrl)
	settings.Visible = false
	addBubble("system", "Servidor: " .. serverUrl)
end)

forgetBtn.Activated:Connect(function()
	alwaysAllow = {}
	plugin:SetSetting("alwaysAllow", alwaysAllow)
	addBubble("system", "Lista de \"permitir sempre\" limpa — volto a perguntar.")
end)

-- Barra de ferramentas -------------------------------------------------------
local toolbar = plugin:CreateToolbar("Claude")
local toggleBtn = toolbar:CreateButton("Claude Agent", "Abrir/fechar o chat do Claude", "")
toggleBtn.ClickableWhenViewportHidden = true
toggleBtn.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	toggleBtn:SetActive(widget.Enabled)
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleBtn:SetActive(widget.Enabled)
end)

updateHeader()
addBubble(
	"assistant",
	"Olá! Sou o Claude, rodando no seu Studio.\n\n"
		.. "Posso ler a hierarquia, escrever scripts, testá-los de verdade e construir "
		.. "sistemas inteiros. Antes de modificar qualquer coisa eu peço permissão — "
		.. "use o botão do topo para trocar entre Perguntar, Aceitar edições e Sem permissões.\n\n"
		.. "Rode o servidor-ponte antes (⚙ muda a URL). Tudo que eu edito volta com Ctrl+Z."
)

-- ----------------------------------------------------------------------------
-- Atualização
-- ----------------------------------------------------------------------------
-- Comparar versão como texto não funciona: "0.10.0" < "0.9.0" em ordem
-- alfabética. Compara número a número.
local function parseVersion(s)
	local parts = {}
	for n in tostring(s):gmatch("%d+") do
		table.insert(parts, tonumber(n))
	end
	return parts
end

local function isNewer(a, b)
	local va, vb = parseVersion(a), parseVersion(b)
	for i = 1, math.max(#va, #vb) do
		local x, y = va[i] or 0, vb[i] or 0
		if x ~= y then
			return x > y
		end
	end
	return false
end

local updateAction = nil
updateBar.MouseButton1Click:Connect(function()
	if updateAction then
		updateAction()
	end
end)

local function showUpdateBar(text, action)
	updateBar.Text = text
	updateAction = action
	updateBar.Visible = true
	-- Empurra o chat e o painel de config para baixo. A barra não pode cobrir a
	-- conversa: ela some sozinha só quando o usuário atualiza, e ficar por cima
	-- de uma mensagem para sempre seria pior que o problema que ela resolve.
	local top = 34 + UPDATE_BAR_H
	scroll.Position = UDim2.new(0, 0, 0, top)
	scroll.Size = UDim2.new(1, 0, 1, -top - 78)
	settings.Position = UDim2.new(0, 0, 0, top)
end

local UPDATE_CMD = "irm https://claybrick.online/install.ps1 | iex"

local function checkForUpdates()
	-- Caso 1: o servidor em disco já está mais novo que este plugin. Quer dizer
	-- que o instalador rodou, trocou os dois, e o Studio ainda tem o plugin
	-- velho na memória. Não falta baixar nada — falta reiniciar.
	local health = getJSON("/health")
	if health and health.version and isNewer(health.version, VERSION) then
		showUpdateBar(
			("Plugin desatualizado (%s → %s) · reinicie o Studio"):format(VERSION, health.version),
			function()
				addBubble(
					"system",
					("O servidor já está na versão %s, mas o Studio ainda está rodando o plugin %s.\n\n"):format(health.version, VERSION)
						.. "O arquivo novo já está na pasta de plugins — o Studio só lê essa pasta quando "
						.. "abre, então feche e abra o Studio para carregá-lo. Não precisa baixar nada."
				)
			end
		)
		return
	end

	-- Caso 2: saiu versão nova lá fora. Aqui sim falta baixar.
	local ok, response = pcall(function()
		return HttpService:RequestAsync({ Url = VERSION_URL, Method = "GET" })
	end)
	if not ok or not response.Success then
		return -- sem internet ou site fora: não é problema do usuário, fica quieto
	end
	local okd, data = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not okd or type(data) ~= "table" or not data.version then
		return
	end
	if isNewer(data.version, VERSION) then
		showUpdateBar(("Nova versão %s disponível · como atualizar"):format(data.version), function()
			addBubble(
				"system",
				("Versão %s disponível (você está na %s).\n\n"):format(data.version, VERSION)
					.. (data.notes and (data.notes .. "\n\n") or "")
					.. "Para atualizar, rode isto num PowerShell:\n\n"
					.. UPDATE_CMD
					.. "\n\nÉ o mesmo comando da instalação: ele atualiza o servidor e o plugin, e "
					.. "preserva sua chave no .env. Depois, feche e abra o Studio."
			)
		end)
	end
end

print("[Claude Studio] carregado. Servidor:", serverUrl, "| backend:", backend, "| modo:", permMode)

-- Procura a ponte já no carregamento, numa thread separada para não travar o
-- Studio abrindo. Assim, quando a pessoa mandar a primeira mensagem, a porta já
-- está resolvida — em vez de a primeira tentativa pagar o custo da varredura.
-- Silencioso de propósito: se o servidor ainda não estiver rodando, não há nada
-- de errado a relatar, e o httpRequest procura de novo quando for a hora.
task.spawn(function()
	if discoverServer() and serverUrl ~= DEFAULT_URL then
		print("[Claude Studio] ponte encontrada em", serverUrl)
	end
	checkForUpdates()
end)
