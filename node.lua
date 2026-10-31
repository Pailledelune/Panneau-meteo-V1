gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

-- Polices DejaVu (licence libre, voir LICENCE-polices.txt)
local sans = resource.load_font "sans.ttf"
local gras = resource.load_font "sans-gras.ttf"

-- Couleurs
local FOND   = {0.055, 0.165, 0.278}
local TUILE  = {0.090, 0.224, 0.369}
local CREUX  = {0.039, 0.122, 0.212}
local BLANC  = {1.000, 1.000, 1.000}
local PALE   = {0.663, 0.757, 0.855}
local NUAGE  = {0.843, 0.886, 0.933}
local GRIS   = {0.561, 0.651, 0.745}
local ORAGE  = {0.478, 0.553, 0.639}
local OR     = {0.961, 0.722, 0.239}
local BLEU   = {0.435, 0.706, 0.941}
local GLACE  = {0.749, 0.902, 1.000}
local CHAUD  = {0.941, 0.478, 0.322}

local blanc = resource.create_colored_texture(1, 1, 1, 1)

-- Reglages (tableau de bord info-beamer) et meteo (service)
local orientation = "paysage"
local ville = "Sarrebourg"
local meteo = {}

util.json_watch("config.json", function(config)
  orientation = config.orientation or orientation
  ville = config.ville or ville
end)

util.json_watch("meteo.json", function(m)
  meteo = m
end)

------------------------------------------------------------------------
-- Shaders
------------------------------------------------------------------------

-- Rectangle a coins arrondis, disque ou trait a bouts ronds
local shader_forme = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float w, h, rayon, r, g, b, alpha;
  void main() {
    vec2 q = abs((TexCoord - vec2(0.5)) * vec2(w, h)) - vec2(w, h) * 0.5 + rayon;
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rayon;
    float a = clamp(0.5 - d, 0.0, 1.0);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(r, g, b, a * alpha);
  }
]]

-- Lune eclairee selon la phase (0 = nouvelle, 0.5 = pleine)
local shader_lune = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float phase, px;
  void main() {
    vec2 p = (TexCoord - vec2(0.5)) * 2.0;
    float d = length(p);
    float a = clamp((1.0 - d) / px + 0.5, 0.0, 1.0);
    float m = sqrt(max(1.0 - p.y * p.y, 0.0)) * cos(phase * 6.2831853);
    float l = phase < 0.5 ? p.x - m : -m - p.x;
    float e = clamp(l / 0.04 + 0.5, 0.0, 1.0);
    vec3 c = vec3(0.93, 0.85, 0.63);
    c -= 0.16 * smoothstep(0.26, 0.20, length(p - vec2(-0.28, 0.25)));
    c -= 0.14 * smoothstep(0.20, 0.14, length(p - vec2(0.30, -0.30)));
    c -= 0.12 * smoothstep(0.15, 0.10, length(p - vec2(0.15, 0.48)));
    c -= 0.12 * smoothstep(0.14, 0.09, length(p - vec2(-0.42, -0.38)));
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(mix(vec3(0.039, 0.122, 0.212), c, e), a);
  }
]]

-- Goutte remplie jusqu'au niveau voulu, avec une petite vague
local shader_goutte = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float niveau, temps, px;
  void main() {
    vec2 p = (TexCoord - vec2(0.5)) * vec2(2.0, -2.0);
    float u = clamp((0.95 - p.y) / 1.9, 0.0, 1.0);
    float l = 1.12 * pow(u, 0.75) * sqrt(1.0 - u);
    float a = clamp((l - abs(p.x)) / px + 0.5, 0.0, 1.0);
    float s = -0.95 + 1.9 * niveau + 0.03 * sin(p.x * 7.0 + temps * 2.0);
    float e = clamp((s - p.y) / px + 0.5, 0.0, 1.0);
    vec3 c = mix(vec3(0.039, 0.122, 0.212), vec3(0.435, 0.706, 0.941), e);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(c, a);
  }
]]

------------------------------------------------------------------------
-- Outils de dessin
------------------------------------------------------------------------

local function forme(x, y, w, h, rayon, c, a)
  shader_forme:use{w = w, h = h, rayon = rayon, r = c[1], g = c[2], b = c[3], alpha = a or 1}
  blanc:draw(x, y, x + w, y + h)
  shader_forme:deactivate()
end

local function disque(x, y, r, c, a)
  forme(x - r, y - r, 2 * r, 2 * r, r, c, a)
end

local function trait(x1, y1, x2, y2, ep, c, a)
  local dx, dy = x2 - x1, y2 - y1
  gl.pushMatrix()
  gl.translate(x1, y1)
  gl.rotate(math.deg(math.atan2(dy, dx)), 0, 0, 1)
  forme(-ep / 2, -ep / 2, math.sqrt(dx * dx + dy * dy) + ep, ep, ep / 2, c, a)
  gl.popMatrix()
end

local function tuile(x, y, w, h)
  forme(x, y, w, h, 22, TUILE)
end

-- Texte centre verticalement sur y ; ancre "g", "c" ou "d"
local function texte(f, t, x, y, taille, c, ancre)
  local w = f:width(t, taille)
  if ancre == "c" then x = x - w / 2 elseif ancre == "d" then x = x - w end
  f:write(x, y - taille / 2, t, taille, c[1], c[2], c[3], 1)
end

-- Reduit la taille pour que le texte tienne dans la largeur
local function ajuste(f, t, taille, largeur)
  local w = f:width(t, taille)
  if w > largeur then return taille * largeur / w end
  return taille
end

local function entier(v)
  return string.format("%d", math.floor(v + 0.5))
end

-- Temperature : le degre est dessine en anneau (fond = tuile)
local function temperature(f, v, x, y, taille, c, ancre)
  local t = v and entier(v) or "--"
  local w = f:width(t, taille)
  local e = taille * 0.30
  if ancre == "c" then x = x - (w + e) / 2 elseif ancre == "d" then x = x - w - e end
  f:write(x, y - taille / 2, t, taille, c[1], c[2], c[3], 1)
  local r = taille * 0.095
  local cx, cy = x + w + e * 0.55, y - taille * 0.27
  disque(cx, cy, r, c)
  disque(cx, cy, r * 0.5, TUILE)
end

------------------------------------------------------------------------
-- Animations de la meteo (dessinees sur environ +/- 100 unites)
------------------------------------------------------------------------

local function nuage(x, y, s, c)
  disque(x - s * 0.45, y + s * 0.10, s * 0.34, c)
  disque(x, y - s * 0.10, s * 0.46, c)
  disque(x + s * 0.45, y + s * 0.10, s * 0.34, c)
  forme(x - s * 0.45, y + s * 0.05, s * 0.90, s * 0.39, 0, c)
end

local function soleil(x, y, r, t)
  for i = 0, 9 do
    local a = t * 0.4 + i * math.pi / 5
    local l = r * (1.55 + 0.12 * math.sin(t * 2.4 + i))
    trait(x + math.cos(a) * r * 1.25, y + math.sin(a) * r * 1.25,
          x + math.cos(a) * l, y + math.sin(a) * l, r * 0.13, OR)
  end
  disque(x, y, r, OR)
end

-- Croissant : un disque clair mordu par un disque couleur de tuile
local function croissant(x, y, r)
  disque(x, y, r, NUAGE)
  disque(x + r * 0.42, y - r * 0.18, r * 0.86, TUILE)
end

local function etoile(x, y, r, t, decalage)
  disque(x, y, r * (0.65 + 0.35 * math.sin(t * 2 + decalage)), OR)
end

local function flocon(x, y, r, a)
  for i = 0, 2 do
    local q = a + i * math.pi / 3
    trait(x - math.cos(q) * r, y - math.sin(q) * r,
          x + math.cos(q) * r, y + math.sin(q) * r, r * 0.28, BLANC)
  end
end

local ANIM = {}

function ANIM.soleil(t)
  soleil(0, 0, 50, t)
end

function ANIM.lune(t)
  croissant(-5, 0, 58)
  etoile(62, -55, 7, t, 0)
  etoile(78, 20, 5, t, 2)
  etoile(-75, -60, 5, t, 4)
  etoile(40, 70, 4, t, 1)
end

function ANIM.eclaircies(t)
  soleil(34, -30, 34, t)
  nuage(-14 + 10 * math.sin(t * 0.5), 26, 76, NUAGE)
end

function ANIM.eclaircies_nuit(t)
  croissant(36, -36, 38)
  etoile(-55, -60, 5, t, 1)
  etoile(85, 18, 4, t, 3)
  nuage(-14 + 10 * math.sin(t * 0.5), 26, 76, NUAGE)
end

function ANIM.nuageux(t)
  local o = math.sin(t * 0.5)
  nuage(-20 + 28 * o, -32, 54, GRIS)
  nuage(16 - 30 * o, 24, 72, NUAGE)
end

function ANIM.brouillard(t)
  for i = 0, 4 do
    local sens = (i % 2 == 0) and -1 or 1
    local o = sens * 26 * math.sin(t * 0.45 + i * 1.3)
    forme(-92 + o, -72 + i * 33, 184, 20, 10, NUAGE, 0.32 + 0.12 * i)
  end
end

function ANIM.pluie(t)
  nuage(0, -38, 70, NUAGE)
  for i = 0, 6 do
    local p = (t * 0.9 + i * 0.37) % 1
    local x = -66 + i * 22 - p * 12
    trait(x, 18 + p * 68, x - 5, 32 + p * 68, 6, BLEU)
  end
end

function ANIM.neige(t)
  nuage(0, -48, 66, NUAGE)
  for i = 0, 8 do
    local p = (t * 0.22 + i * 0.31) % 1
    local x = -88 + i * 22 + 9 * math.sin(t + i * 2)
    flocon(x, 6 + p * 92, 7 + (i % 3) * 2, t * ((i % 2 == 0) and 0.8 or -0.8))
  end
end

function ANIM.verglas(t)
  -- Gouttiere, stalactites qui gouttent
  trait(-100, -80, 100, -80, 8, NUAGE)
  for i = 0, 4 do
    local x = -80 + i * 40
    local l = 30 + (i % 2) * 18 + 4 * math.sin(t * 2 + i)
    trait(x, -78, x, -78 + l * 0.45, 15, GLACE)
    trait(x, -78, x, -78 + l * 0.75, 9, GLACE)
    trait(x, -78, x, -78 + l, 4, GLACE)
    local q = (t * 0.4 + i * 0.2) % 1
    disque(x, -78 + l + q * 92, 3.5, GLACE, 1 - q * 0.5)
  end
  -- Route gelee et reflet qui glisse
  forme(-110, 62, 220, 16, 8, {0.169, 0.361, 0.549})
  local p = (t * 0.35) % 1
  forme(-110 + p * 190, 64, 30, 12, 6, BLANC, math.sin(p * math.pi) * 0.7)
  -- Triangle de danger qui clignote doucement
  local a = 0.5 + 0.5 * (math.sin(t * 3) + 1) / 2
  trait(58, 30, 82, -12, 6, OR, a)
  trait(82, -12, 106, 30, 6, OR, a)
  trait(58, 30, 106, 30, 6, OR, a)
  trait(82, 0, 82, 12, 5, OR, a)
  disque(82, 22, 3, OR, a)
end

function ANIM.orage(t)
  local p = t % 3.2
  local eclair = p < 0.12 or (p > 0.22 and p < 0.32)
  if eclair then forme(-105, -105, 210, 210, 22, BLANC, 0.12) end
  nuage(0, -46, 70, ORAGE)
  local c = eclair and {1.0, 0.88, 0.54} or OR
  trait(10, 0, -18, 38, 13, c)
  trait(-18, 38, 16, 34, 13, c)
  trait(16, 34, -8, 84, 12, c)
end

local function animation(nom, x, y, s, t)
  gl.pushMatrix()
  gl.translate(x, y)
  gl.scale(s, s, 1)
  local a = ANIM[nom] or ANIM.nuageux
  a(t)
  gl.popMatrix()
end

------------------------------------------------------------------------
-- Animations des mesures
------------------------------------------------------------------------

local function thermometre(v, t)
  forme(-13, -92, 26, 130, 13, CREUX)
  disque(0, 58, 32, CREUX)
  local c = (v or 0) >= 18 and CHAUD or ((v or 0) <= 3 and BLEU or OR)
  local f = math.max(0, math.min(1, ((v or 0) + 20) / 60))
  local h = 16 + f * 104 + 2 * math.sin(t * 1.5)
  forme(-7, 46 - h, 14, h + 14, 7, c)
  disque(0, 58, 24, c)
end

local function goutte(v, t)
  shader_goutte:use{niveau = (v or 0) / 100, temps = t, px = 0.012}
  blanc:draw(-95, -95, 95, 95)
  shader_goutte:deactivate()
end

local function barometre(v, t)
  local f = math.max(0, math.min(1, ((v or 960) - 960) / 100))
  for i = 0, 20 do
    local a = math.rad(-180 + i * 9)
    local c = (i / 20 <= f) and OR or CREUX
    trait(math.cos(a) * 76, 28 + math.sin(a) * 76,
          math.cos(a) * 94, 28 + math.sin(a) * 94, 7, c)
  end
  local a = math.rad(-180 + f * 180) + 0.012 * math.sin(t * 3)
  trait(0, 28, math.cos(a) * 68, 28 + math.sin(a) * 68, 7, NUAGE)
  disque(0, 28, 12, NUAGE)
end

-- L'eolienne tourne d'autant plus vite que le vent est fort
local angle_vent, dernier = 0, nil

local function eolienne(v, t)
  if dernier then angle_vent = angle_vent + (t - dernier) * (0.3 + (v or 0) * 0.12) end
  dernier = t
  trait(0, -10, 0, 98, 8, PALE)
  for i = 0, 2 do
    local a = angle_vent + i * 2.0944
    trait(0, -10, math.cos(a) * 80, -10 + math.sin(a) * 80, 11, NUAGE)
  end
  disque(0, -10, 10, OR)
end

local function minutes(h)
  if not h then return nil end
  local a, b = h:match("(%d+):(%d+)")
  return a and tonumber(a) * 60 + tonumber(b)
end

-- Soleil pose sur son arc entre le lever et le coucher
local function course(lever, coucher, maintenant, t)
  for i = 0, 18 do
    local a = math.rad(-180 + i * 10)
    disque(math.cos(a) * 108, 62 + math.sin(a) * 108, 3, PALE)
  end
  trait(-135, 62, 135, 62, 4, PALE)
  if lever and coucher and coucher > lever then
    local f = (maintenant - lever) / (coucher - lever)
    if f >= 0 and f <= 1 then
      local a = math.rad(-180 + f * 180)
      soleil(math.cos(a) * 108, 62 + math.sin(a) * 108, 18, t)
    end
  end
end

local function lune_phase(age, r)
  shader_lune:use{phase = age / 29.530588, px = 1.5 / r}
  blanc:draw(-r, -r, r, r)
  shader_lune:deactivate()
end

local function tuile_mesure(x, y, w, h, titre, dessin, valeur, t)
  tuile(x, y, w, h)
  texte(sans, titre, x + w / 2, y + h * 0.13, h * 0.10, PALE, "c")
  gl.pushMatrix()
  gl.translate(x + w / 2, y + h * 0.48)
  local s = h / 480
  gl.scale(s, s, 1)
  dessin(t)
  gl.popMatrix()
  if valeur then
    texte(gras, valeur, x + w / 2, y + h * 0.85, ajuste(gras, valeur, h * 0.15, w - 30), BLANC, "c")
  end
end

local BOUSSOLE = {"N", "NE", "E", "SE", "S", "SO", "O", "NO"}

local function nom_direction(d)
  return BOUSSOLE[math.floor(((d or 0) + 22.5) / 45) % 8 + 1]
end

local function nom_phase(a)
  if a < 1.0 or a >= 28.5 then return "Nouvelle lune" end
  if a < 6.4 then return "Premier croissant" end
  if a < 8.4 then return "Premier quartier" end
  if a < 13.8 then return "Gibbeuse croissante" end
  if a < 15.8 then return "Pleine lune" end
  if a < 21.1 then return "Gibbeuse décroissante" end
  if a < 23.1 then return "Dernier quartier" end
  return "Dernier croissant"
end

-- Les six mesures, chacune dans la tuile indiquee
local function mesures(place, age, heure_locale, t)
  local m = meteo
  local x, y, w, h = place(0)
  tuile_mesure(x, y, w, h, "Ressenti", function(q) thermometre(m.ressenti, q) end, nil, t)
  temperature(gras, m.ressenti, x + w / 2, y + h * 0.85, h * 0.15, BLANC, "c")

  x, y, w, h = place(1)
  tuile_mesure(x, y, w, h, "Hygrométrie", function(q) goutte(m.humidite, q) end,
    m.humidite and (entier(m.humidite) .. " %") or "--", t)

  x, y, w, h = place(2)
  tuile_mesure(x, y, w, h, "Pression", function(q) barometre(m.pression, q) end,
    m.pression and (entier(m.pression) .. " hPa") or "--", t)

  x, y, w, h = place(3)
  tuile_mesure(x, y, w, h, "Vent", function(q) eolienne(m.vent, q) end,
    m.vent and (entier(m.vent) .. " km/h " .. nom_direction(m.direction)) or "--", t)

  x, y, w, h = place(4)
  tuile_mesure(x, y, w, h, "Soleil", function(q)
    course(minutes(m.lever), minutes(m.coucher), heure_locale, q)
  end, nil, t)
  local ts = h * 0.13
  texte(gras, m.lever or "--", x + 18, y + h * 0.85, ts, OR, "g")
  texte(gras, m.coucher or "--", x + w - 18, y + h * 0.85, ts, OR, "d")

  x, y, w, h = place(5)
  tuile_mesure(x, y, w, h, "Lune", function() lune_phase(age, 88) end, nil, t)
  local n = nom_phase(age)
  texte(sans, n, x + w / 2, y + h * 0.85, ajuste(sans, n, h * 0.10, w - 24), PALE, "c")
end

------------------------------------------------------------------------
-- Heure et lune
------------------------------------------------------------------------

local JOURS = {[0] = "Dimanche", "Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi"}
local JOURS_COURTS = {[0] = "Dim.", "Lun.", "Mar.", "Mer.", "Jeu.", "Ven.", "Sam."}
local MOIS = {"janvier", "février", "mars", "avril", "mai", "juin", "juillet",
              "août", "septembre", "octobre", "novembre", "décembre"}

local function jour_semaine(y, m, d)   -- 0 = dimanche
  local t = {0,3,2,5,0,3,5,2,6,4,2,4}
  if m < 3 then y = y - 1 end
  return (y + math.floor(y/4) - math.floor(y/100) + math.floor(y/400) + t[m] + d) % 7
end

-- Heure de Paris tant que le service n'a pas donne le fuseau de la ville
local function decalage_paris(utc)
  local debut = 3 * 10000 + (31 - jour_semaine(utc.year, 3, 31)) * 100 + 1
  local fin   = 10 * 10000 + (31 - jour_semaine(utc.year, 10, 31)) * 100 + 1
  local now   = utc.month * 10000 + utc.day * 100 + utc.hour
  if now >= debut and now < fin then return 7200 end
  return 3600
end

-- Age de la lune en jours (nouvelle lune de reference : 6 janvier 2000, 18h14 UTC)
local function age_lune(t)
  return ((t - 947182440) / 86400) % 29.530588
end

-- Libelle de la meteo actuelle, ou raison de son absence
local function libelle_meteo(t)
  if meteo.erreur then return meteo.erreur end
  if not meteo.maj then return "Connexion à la météo" end
  if t - meteo.maj > 3 * 3600 then return "Météo non actualisée" end
  return meteo.libelle or ""
end

-- Coupe un libelle en deux lignes si besoin
local function libelle(t, x, y, taille, largeur, ancre)
  if sans:width(t, taille) <= largeur then
    texte(sans, t, x, y, taille, PALE, ancre)
    return
  end
  local a, b = t:match("^(%S+)%s+(.+)$")
  if not a then
    texte(sans, t, x, y, ajuste(sans, t, taille, largeur), PALE, ancre)
    return
  end
  local s = math.min(ajuste(sans, a, taille, largeur), ajuste(sans, b, taille, largeur))
  texte(sans, a, x, y - s * 0.62, s, PALE, ancre)
  texte(sans, b, x, y + s * 0.62, s, PALE, ancre)
end

------------------------------------------------------------------------
-- Mises en page (1920 x 1080 ou 1080 x 1920)
------------------------------------------------------------------------

local function prevision_tuile(p, x, y, w, h, t)
  tuile(x, y, w, h)
  texte(sans, JOURS_COURTS[p.jour] .. " " .. p.quantieme, x + w / 2, y + 56, 44, PALE, "c")
  animation(p.anim, x + w / 2, y + 160, 0.68, t)
  temperature(gras, p.max, x + w / 2 - 14, y + 298, 64, BLANC, "d")
  temperature(sans, p.min, x + w / 2 + 16, y + 298, 48, PALE, "g")
  if p.pluie then
    texte(sans, "Pluie " .. entier(p.pluie) .. " %", x + w / 2, y + 348, 32, BLEU, "c")
  end
end

local function prevision_ligne(p, x, y, w, h, t)
  tuile(x, y, w, h)
  texte(gras, JOURS_COURTS[p.jour] .. " " .. p.quantieme, x + 36, y + h / 2, 42, BLANC, "g")
  animation(p.anim, x + 360, y + h / 2, 0.40, t)
  temperature(gras, p.max, x + 580, y + h / 2, 46, BLANC, "c")
  temperature(sans, p.min, x + 720, y + h / 2, 42, PALE, "c")
  if p.pluie then
    texte(sans, entier(p.pluie) .. " %", x + w - 36, y + h / 2, 38, BLEU, "d")
  end
end

local function paysage(d, age, t, ts)
  -- Lieu, heure et date
  tuile(40, 40, 860, 300)
  texte(gras, meteo.ville or ville, 80, 96, ajuste(gras, meteo.ville or ville, 54, 500), OR, "g")
  texte(gras, string.format("%02d:%02d", d.hour, d.min), 80, 222, 150, BLANC, "g")
  texte(gras, JOURS[d.wday - 1], 860, 96, 44, BLANC, "d")
  texte(gras, tostring(d.day), 860, 168, 76, BLANC, "d")
  texte(sans, MOIS[d.month], 860, 238, 42, PALE, "d")
  texte(sans, tostring(d.year), 860, 292, 42, PALE, "d")

  -- Temps actuel
  tuile(920, 40, 960, 300)
  animation(meteo.anim or "nuageux", 1060, 190, 1.15, t)
  temperature(gras, meteo.temperature, 1500, 190, 170, BLANC, "d")
  libelle(libelle_meteo(ts), 1530, 190, 40, 325, "g")

  -- Mesures
  mesures(function(i) return 40 + i * 309, 360, 295, 280 end, age, d.hour * 60 + d.min, t)

  -- Previsions
  for i, p in ipairs(meteo.previsions or {}) do
    prevision_tuile(p, 40 + (i - 1) * 371, 660, 356, 380, t)
  end
end

local function portrait(d, age, t, ts)
  local date = JOURS[d.wday - 1] .. " " .. d.day .. " " .. MOIS[d.month] .. " " .. d.year

  tuile(40, 40, 1000, 430)
  texte(gras, meteo.ville or ville, 540, 110, ajuste(gras, meteo.ville or ville, 62, 920), OR, "c")
  texte(gras, string.format("%02d:%02d", d.hour, d.min), 540, 270, 170, BLANC, "c")
  texte(sans, date, 540, 410, ajuste(sans, date, 48, 920), PALE, "c")

  tuile(40, 490, 1000, 330)
  animation(meteo.anim or "nuageux", 190, 655, 1.15, t)
  temperature(gras, meteo.temperature, 680, 655, 170, BLANC, "d")
  libelle(libelle_meteo(ts), 700, 655, 40, 310, "g")

  mesures(function(i)
    return 40 + (i % 3) * 340, 840 + math.floor(i / 3) * 254, 320, 240
  end, age, d.hour * 60 + d.min, t)

  for i, p in ipairs(meteo.previsions or {}) do
    prevision_ligne(p, 40, 1354 + (i - 1) * 108, 1000, 98, t)
  end
end

function node.render()
  gl.clear(FOND[1], FOND[2], FOND[3], 1)

  -- Orientation : L x H est la taille de l'ecran une fois tourne
  local L, H = WIDTH, HEIGHT
  if orientation == "portrait_gauche" then
    gl.translate(WIDTH, 0)
    gl.rotate(90, 0, 0, 1)
    L, H = HEIGHT, WIDTH
  elseif orientation == "portrait_droite" then
    gl.translate(0, HEIGHT)
    gl.rotate(-90, 0, 0, 1)
    L, H = HEIGHT, WIDTH
  end

  local base_l, base_h = 1920, 1080
  if L < H then base_l, base_h = 1080, 1920 end
  local k = math.min(L / base_l, H / base_h)
  gl.translate((L - base_l * k) / 2, (H - base_h * k) / 2)
  gl.scale(k, k, 1)

  local ts  = os.time()
  local utc = os.date("!*t", ts)
  local d   = os.date("!*t", ts + (meteo.decalage or decalage_paris(utc)))
  local t   = sys.now()

  if L < H then
    portrait(d, age_lune(ts), t, ts)
  else
    paysage(d, age_lune(ts), t, ts)
  end
end
