gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

-- Polices Poppins (licence libre, voir OFL-poppins.txt)
local sans = resource.load_font "poppins.ttf"
local gras = resource.load_font "poppins-gras.ttf"

-- Couleurs fixes
local BLANC  = {1.000, 1.000, 1.000}
local PALE   = {0.663, 0.757, 0.855}
local NUAGE  = {0.843, 0.886, 0.933}
local GRIS   = {0.561, 0.651, 0.745}
local ORAGE  = {0.478, 0.553, 0.639}
local OR     = {0.961, 0.722, 0.239}
local BLEU   = {0.435, 0.706, 0.941}
local GLACE  = {0.749, 0.902, 1.000}
local VERT   = {0.482, 0.776, 0.494}
local JAUNE  = {0.949, 0.831, 0.361}
local ORANGE = {0.949, 0.651, 0.353}
local ROUGE  = {0.910, 0.412, 0.353}
local VIOLET = {0.714, 0.427, 0.827}

-- Teintes de jour et de nuit
local JOUR = {
  fond  = {0.055, 0.165, 0.278},
  tuile = {0.090, 0.224, 0.369},
  creux = {0.039, 0.122, 0.212},
}
local NUIT = {
  fond  = {0.027, 0.090, 0.165},
  tuile = {0.055, 0.153, 0.251},
  creux = {0.020, 0.059, 0.110},
}

-- Teintes du moment, recalculees a chaque image
local FOND, TUILE, CREUX = {0, 0, 0}, {0, 0, 0}, {0, 0, 0}

local blanc = resource.create_colored_texture(1, 1, 1, 1)

-- Colonnes de la courbe : alternance une heure sur deux, jour ou nuit
local function texture_hex(r, g, b)
  return resource.create_colored_texture(r / 255, g / 255, b / 255, 1)
end
local COLONNES = {
  [true]  = {[0] = texture_hex(0x33, 0x63, 0x90), texture_hex(0x3B, 0x6E, 0x9E)},
  [false] = {[0] = texture_hex(0x0F, 0x2B, 0x48), texture_hex(0x0B, 0x23, 0x3D)},
}
local BASES = {[true] = texture_hex(0x27, 0x51, 0x7A), [false] = texture_hex(0x0A, 0x1F, 0x36)}

-- Reglages (tableau de bord info-beamer) et meteo (service)
local orientation = "paysage"
local duree_ville = 20
local villes = {}
local meteo = {}

util.json_watch("config.json", function(config)
  orientation = config.orientation or orientation
  duree_ville = math.max(5, config.duree or duree_ville)
end)

util.json_watch("meteo.json", function(m)
  villes = m.villes or {}
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
  uniform float phase, px, r0, g0, b0;
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
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(mix(vec3(r0, g0, b0), c, e), a);
  }
]]

-- Goutte a pointe fine et bas rond, remplie jusqu'au niveau voulu
local shader_goutte = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float niveau, temps, px, r0, g0, b0;
  void main() {
    vec2 p = (TexCoord - vec2(0.5)) * vec2(2.0, -2.0);
    float l;
    if (p.y < -0.05) l = sqrt(max(0.4096 - (p.y + 0.28) * (p.y + 0.28), 0.0));
    else l = 0.597 * pow(max((0.98 - p.y) / 1.03, 0.0), 1.4);
    float a = clamp((l - abs(p.x)) / px + 0.5, 0.0, 1.0);
    float s = -0.92 + 1.9 * niveau + 0.03 * sin(p.x * 7.0 + temps * 2.0);
    float e = clamp((s - p.y) / px + 0.5, 0.0, 1.0);
    vec3 c = mix(vec3(r0, g0, b0), vec3(0.435, 0.706, 0.941), e);
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
  forme(x, y, w, h, 20, TUILE)
end

-- Texte pose sur sa ligne de base y ; ancre "g", "c" ou "d"
local function texte(f, t, x, y, taille, c, ancre)
  local w = f:width(t, taille)
  if ancre == "c" then x = x - w / 2 elseif ancre == "d" then x = x - w end
  f:write(x, y - taille * 0.85, t, taille, c[1], c[2], c[3], 1)
end

-- Reduit la taille pour que le texte tienne dans la largeur
local function ajuste(f, t, taille, largeur)
  local w = f:width(t, taille)
  if w > largeur then return taille * largeur / w end
  return taille
end

local function arrondi(v)
  return math.floor(v + 0.5)
end

local function entier(v)
  return string.format("%d", arrondi(v))
end

local function signe(v)
  local n = arrondi(v)
  if n > 0 then return "+" .. n end
  return tostring(n)
end

-- Echelle de couleurs des temperatures
local function couleur_temp(v)
  local n = arrondi(v or 0)
  if n <= 0 then return BLANC end
  if n <= 11 then return BLEU end
  if n <= 20 then return JAUNE end
  if n <= 30 then return {0.949, 0.604, 0.243} end
  return {0.898, 0.325, 0.239}
end

-- Le degre est dessine en anneau, sur le fond de la tuile
local function anneau(x, y, r, c, fond)
  disque(x, y, r, c)
  disque(x, y, r * 0.5, fond or TUILE)
end

local function temperature(f, v, x, y, taille, c, ancre, fond)
  local t = v and entier(v) or "--"
  local w = f:width(t, taille)
  local e = taille * 0.30
  if ancre == "c" then x = x - (w + e) / 2 elseif ancre == "d" then x = x - w - e end
  f:write(x, y - taille * 0.85, t, taille, c[1], c[2], c[3], 1)
  anneau(x + w + e * 0.55, y - taille * 0.62, taille * 0.095, c, fond)
end

-- "-1 degre en 3 h", le degre etant dessine
local function ecart_degres(f, v, x, y, taille, c, ancre)
  if not v then return end
  local a, b = signe(v), " en 3 h"
  local wa, wb = f:width(a, taille), f:width(b, taille)
  local e = taille * 0.36
  if ancre == "c" then x = x - (wa + e + wb) / 2 end
  f:write(x, y - taille * 0.85, a, taille, c[1], c[2], c[3], 1)
  anneau(x + wa + e * 0.5, y - taille * 0.62, taille * 0.13, c)
  f:write(x + wa + e, y - taille * 0.85, b, taille, c[1], c[2], c[3], 1)
end

-- Fleche de tendance : monte (or), baisse (bleu) ou stable (pale)
local function fleche(x, y, v, seuil, s)
  if not v then return end
  local angle, c = 0, PALE
  if v >= seuil then angle, c = -45, OR
  elseif v <= -seuil then angle, c = 45, BLEU end
  gl.pushMatrix()
  gl.translate(x, y)
  gl.rotate(angle, 0, 0, 1)
  gl.scale(s, s, 1)
  trait(-9, 0, 9, 0, 3, c)
  trait(3, -6, 9, 0, 3, c)
  trait(3, 6, 9, 0, 3, c)
  gl.popMatrix()
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

local function place(x, y, s, dessin, ...)
  gl.pushMatrix()
  gl.translate(x, y)
  gl.scale(s, s, 1)
  dessin(...)
  gl.popMatrix()
end

local function animation(nom, x, y, s, t)
  place(x, y, s, ANIM[nom] or ANIM.nuageux, t)
end

------------------------------------------------------------------------
-- Animations des mesures
------------------------------------------------------------------------

local function thermometre(v, t)
  forme(-13, -92, 26, 130, 13, CREUX)
  disque(0, 58, 32, CREUX)
  local c = couleur_temp(v)
  local f = math.max(0, math.min(1, ((v or 0) + 20) / 60))
  local h = 16 + f * 104 + 2 * math.sin(t * 1.5)
  forme(-7, 46 - h, 14, h + 14, 7, c)
  disque(0, 58, 24, c)
end

local function goutte(v, t)
  shader_goutte:use{
    niveau = (v or 0) / 100, temps = t, px = 0.012,
    r0 = CREUX[1], g0 = CREUX[2], b0 = CREUX[3],
  }
  blanc:draw(-100, -100, 100, 100)
  shader_goutte:deactivate()
  trait(-38, 34, -33, 52, 7, BLANC, 0.55)
  trait(-33, 52, -16, 68, 7, BLANC, 0.55)
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

local function lune_phase(age)
  shader_lune:use{
    phase = age / 29.530588, px = 0.017,
    r0 = CREUX[1], g0 = CREUX[2], b0 = CREUX[3],
  }
  blanc:draw(-88, -88, 88, 88)
  shader_lune:deactivate()
end

local function couleur_uv(n)
  if n <= 2 then return VERT end
  if n <= 5 then return JAUNE end
  if n <= 7 then return ORANGE end
  if n <= 10 then return ROUGE end
  return VIOLET
end

local function nom_uv(n)
  if n <= 2 then return "Faible" end
  if n <= 5 then return "Modéré" end
  if n <= 7 then return "Élevé" end
  if n <= 10 then return "Très élevé" end
  return "Extrême"
end

local function barres_uv(v)
  local n = arrondi(v or 0)
  for i = 0, 9 do
    local h = 16 + i * 7
    forme(-110 + i * 22.4, 30 - h, 17, h, 3, (i < n) and couleur_uv(n) or CREUX)
  end
end

-- Indice europeen de qualite de l'air
local function air_info(v)
  if v <= 20 then return "Très bon", VERT end
  if v <= 40 then return "Bon", VERT end
  if v <= 60 then return "Moyen", JAUNE end
  if v <= 80 then return "Médiocre", ORANGE end
  if v <= 100 then return "Mauvais", ROUGE end
  return "Très mauvais", VIOLET
end

local function jauge_air(v)
  local _, c = air_info(v or 0)
  local f = math.min(1, (v or 0) / 100)
  for i = 0, 35 do
    local a = math.rad(-90 + i * 10)
    trait(math.cos(a) * 66, math.sin(a) * 66, math.cos(a) * 82, math.sin(a) * 82, 7,
          (v and i / 36 < f) and c or CREUX)
  end
  if v then texte(gras, entier(v), 0, 15, 42, BLANC, "c") end
end

local BOUSSOLE = {"N", "NE", "E", "SE", "S", "SO", "O", "NO"}

local function nom_direction(d)
  return BOUSSOLE[math.floor(((d or 0) + 22.5) / 45) % 8 + 1]
end

local function nom_phase(a)
  if a < 1.0 or a >= 28.5 then return "Nouvelle lune" end
  if a < 6.4 then return "1er croissant" end
  if a < 8.4 then return "1er quartier" end
  if a < 13.8 then return "Gibbeuse crois." end
  if a < 15.8 then return "Pleine lune" end
  if a < 21.1 then return "Gibbeuse déc." end
  if a < 23.1 then return "Dernier quartier" end
  return "Dernier croissant"
end

local MOIS_COURTS = {"janv.", "févr.", "mars", "avril", "mai", "juin", "juil.",
                     "août", "sept.", "oct.", "nov.", "déc."}

-- Cadre commun d'une mesure : titre et animation
local function tuile_mesure(x, y, w, h, titre, dessin, ...)
  tuile(x, y, w, h)
  texte(sans, titre, x + w / 2, y + h * 0.15, ajuste(sans, titre, h * 0.095, w - 20), PALE, "c")
  place(x + w / 2, y + h * 0.42, h / 560, dessin, ...)
end

-- Valeur centree avec sa fleche, ligne d'information en dessous
local function valeur(x, y, w, h, t, ecart, seuil)
  local f = h * 0.135
  f = ajuste(gras, t, f, w - (ecart and 66 or 24))
  local vy = y + h * 0.77
  local l = gras:width(t, f)
  local depart = x + w / 2 - (l + (ecart and 34 or 0)) / 2
  texte(gras, t, depart, vy, f, BLANC, "g")
  fleche(depart + l + 20, vy - f * 0.33, ecart, seuil, 1.15)
end

local function detail(x, y, w, h, t)
  texte(sans, t, x + w / 2, y + h * 0.92, ajuste(sans, t, h * 0.075, w - 16), PALE, "c")
end

-- Les huit mesures, chacune dans la tuile indiquee par "case"
local function mesures(case, age, maintenant, t)
  local m = meteo
  local e = m.ecarts or {}

  local x, y, w, h = case(0)
  tuile_mesure(x, y, w, h, "Ressenti", thermometre, m.ressenti, t)
  local f = h * 0.135
  local vy = y + h * 0.77
  temperature(gras, m.ressenti, x + w / 2 - 14, vy, f, BLANC, "c")
  fleche(x + w / 2 + f * 0.75, vy - f * 0.33, e.ressenti, 0.5, 1.15)
  ecart_degres(sans, e.ressenti, x + w / 2, y + h * 0.92, h * 0.075, PALE, "c")

  x, y, w, h = case(1)
  tuile_mesure(x, y, w, h, "Hygrométrie", goutte, m.humidite, t)
  valeur(x, y, w, h, m.humidite and (entier(m.humidite) .. " %") or "--", e.humidite, 2)
  if e.humidite then detail(x, y, w, h, signe(e.humidite) .. " % en 3 h") end

  x, y, w, h = case(2)
  tuile_mesure(x, y, w, h, "Pression", barometre, m.pression, t)
  valeur(x, y, w, h, m.pression and (entier(m.pression) .. " hPa") or "--", e.pression, 1)
  if e.pression then detail(x, y, w, h, signe(e.pression) .. " hPa en 3 h") end

  x, y, w, h = case(3)
  tuile_mesure(x, y, w, h, "Vent", eolienne, m.vent, t)
  valeur(x, y, w, h, m.vent and (entier(m.vent) .. " km/h") or "--", e.vent, 3)
  if m.vent then
    detail(x, y, w, h, nom_direction(m.direction) .. ", rafales " .. entier(m.rafales or m.vent))
  end

  x, y, w, h = case(4)
  tuile_mesure(x, y, w, h, "Soleil", course, minutes(m.lever), minutes(m.coucher), maintenant, t)
  local ts = h * 0.105
  texte(gras, m.lever or "--", x + 14, y + h * 0.77, ts, OR, "g")
  texte(gras, m.coucher or "--", x + w - 14, y + h * 0.77, ts, OR, "d")
  fleche(x + w / 2, y + h * 0.77 - ts * 0.33, m.ecart_jour, 1, 0.9)
  if m.duree_jour then
    detail(x, y, w, h, string.format("Jour %d h %02d, %s min",
      math.floor(m.duree_jour / 60), m.duree_jour % 60, signe(m.ecart_jour or 0)))
  end

  x, y, w, h = case(5)
  tuile_mesure(x, y, w, h, "Lune", lune_phase, age)
  local n = nom_phase(age)
  texte(gras, n, x + w / 2, y + h * 0.77, ajuste(gras, n, h * 0.085, w - 20), BLANC, "c")
  if m.pleine_lune then
    detail(x, y, w, h, "Pleine lune " .. m.pleine_lune.jour .. " " .. MOIS_COURTS[m.pleine_lune.mois])
  end

  x, y, w, h = case(6)
  tuile_mesure(x, y, w, h, "Indice UV", barres_uv, m.uv)
  valeur(x, y, w, h, m.uv and entier(m.uv) or "--", e.uv, 1)
  if m.uv then detail(x, y, w, h, nom_uv(arrondi(m.uv))) end

  x, y, w, h = case(7)
  tuile_mesure(x, y, w, h, "Qualité de l'air", jauge_air, m.air)
  valeur(x, y, w, h, m.air and (air_info(m.air)) or "--", e.air, 5)
  if m.air then detail(x, y, w, h, "IQA " .. entier(m.air)) end
end

------------------------------------------------------------------------
-- Courbe des prochaines 24 heures
------------------------------------------------------------------------

-- Legende : un trait pour la temperature, une barre pour le risque de pluie
local function legende_temp(x, y, taille)
  trait(x, y - taille * 0.33, x + 30, y - taille * 0.33, 4, OR)
  texte(sans, "T", x + 44, y, taille, PALE, "g")
  anneau(x + 44 + sans:width("T", taille) + taille * 0.22, y - taille * 0.62, taille * 0.13, PALE)
end

local function legende_pluie(x, y, taille)
  forme(x, y - taille * 0.78, 30, taille * 0.86, 3, BLEU, 0.8)
  texte(sans, "% pluie", x + 44, y, taille, PALE, "g")
end

local function courbe(ox, oy, w, h, gauche, colonne)
  tuile(ox, oy, w, h)
  if colonne then
    texte(sans, "Prochaines", ox + 24, oy + 58, 24, PALE, "g")
    texte(sans, "24 heures", ox + 24, oy + 90, 24, PALE, "g")
    legende_temp(ox + 24, oy + 146, 22)
    legende_pluie(ox + 24, oy + 182, 22)
  else
    texte(sans, "Prochaines 24 heures", ox + 24, oy + 36, 26, PALE, "g")
    legende_temp(ox + w - 300, oy + 36, 24)
    legende_pluie(ox + w - 170, oy + 36, 24)
  end

  local points = meteo.courbe
  if not points or #points < 2 then return end

  local haut = oy + (colonne and 12 or 50)
  local bas = oy + h - 42
  local bw = (w - gauche - 12) / #points
  local mini, maxi = 1000, -1000
  for _, p in ipairs(points) do
    mini = math.min(mini, p.t)
    maxi = math.max(maxi, p.t)
  end
  if maxi - mini < 4 then
    local m = (maxi + mini) / 2
    mini, maxi = m - 2, m + 2
  end

  local function px(i) return ox + gauche + (i - 0.5) * bw end
  local function py(v) return haut + 36 + (maxi - v) / (maxi - mini) * (bas - haut - 80) end

  -- Colonnes, heure a la base, barre de pluie
  local taille = math.min(20, bw * 0.52)
  for i, p in ipairs(points) do
    local x = ox + gauche + (i - 1) * bw
    COLONNES[p.j][p.h % 2]:draw(x, haut, x + bw - 2, bas)
    BASES[p.j]:draw(x, bas, x + bw - 2, bas + 30)
    texte(p.j and gras or sans, string.format("%02d", p.h), x + bw / 2 - 1, bas + 22, taille,
          p.j and BLANC or PALE, "c")
    if p.p > 0 then
      local b = p.p * 0.6
      forme(x + bw * 0.2, bas - b, bw * 0.6 - 2, b, 3, BLEU, 0.8)
      if p.p >= 10 then
        texte(sans, entier(p.p), x + bw / 2 - 1, bas - b - 5, taille * 0.9, BLEU, "c")
      end
    end
  end

  -- Ligne, points colores, valeur toutes les 3 heures
  for i = 2, #points do
    trait(px(i - 1), py(points[i - 1].t), px(i), py(points[i].t), 4, OR)
  end
  for i, p in ipairs(points) do
    local c = couleur_temp(p.t)
    if (i - 1) % 3 == 0 then
      disque(px(i), py(p.t), 6, c)
      temperature(gras, p.t, px(i), py(p.t) - 13, 22, c, "c", p.j and {0.22, 0.42, 0.60} or {0.05, 0.15, 0.25})
    else
      disque(px(i), py(p.t), 3.5, c)
    end
  end
end

------------------------------------------------------------------------
-- Heure, lune et teinte
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

-- Passe en douceur (45 minutes) de la teinte de jour a celle de nuit
local function teinte(maintenant)
  local lever, coucher = minutes(meteo.lever) or 420, minutes(meteo.coucher) or 1140
  local f = math.max(0, math.min(1, (maintenant - lever) / 45 + 0.5))
  local g = math.max(0, math.min(1, (coucher - maintenant) / 45 + 0.5))
  local j = math.min(f, g)
  for i = 1, 3 do
    FOND[i]  = NUIT.fond[i]  + (JOUR.fond[i]  - NUIT.fond[i])  * j
    TUILE[i] = NUIT.tuile[i] + (JOUR.tuile[i] - NUIT.tuile[i]) * j
    CREUX[i] = NUIT.creux[i] + (JOUR.creux[i] - NUIT.creux[i]) * j
  end
end

-- Libelle de la meteo actuelle, ou raison de son absence
local function libelle_meteo(t)
  if meteo.erreur then return meteo.erreur end
  if not meteo.maj then return "Connexion à la météo" end
  if t - meteo.maj > 3 * 3600 then return "Météo non actualisée" end
  return meteo.libelle or ""
end

-- Coupe un libelle en deux lignes si besoin ; y = milieu du bloc
local function libelle(t, x, y, taille, largeur)
  if sans:width(t, taille) <= largeur then
    texte(sans, t, x, y + taille * 0.35, taille, PALE, "g")
    return
  end
  local a, b = t:match("^(%S+)%s+(.+)$")
  if not a then
    local s = ajuste(sans, t, taille, largeur)
    texte(sans, t, x, y + s * 0.35, s, PALE, "g")
    return
  end
  local s = math.min(ajuste(sans, a, taille, largeur), ajuste(sans, b, taille, largeur))
  texte(sans, a, x, y - s * 0.20, s, PALE, "g")
  texte(sans, b, x, y + s * 1.05, s, PALE, "g")
end

-- Points indiquant la ville affichee ; x = premier point ou milieu
local function points_villes(x, y, rang, centre)
  local n = #villes
  if n < 2 then return end
  if centre then x = x - (n - 1) * 10 end
  for i = 1, n do
    disque(x + (i - 1) * 20, y, 6, (i == rang) and OR or PALE)
  end
end

------------------------------------------------------------------------
-- Mises en page (1920 x 1080 ou 1080 x 1920)
------------------------------------------------------------------------

-- Fondu entre deux villes : seules les valeurs s'effacent, les tuiles et les
-- titres restent en place. Chaque zone est recouverte de la couleur de tuile.
local function voiles(zones, a)
  if a <= 0 then return end
  for _, z in ipairs(zones) do
    forme(z[1], z[2], z[3], z[4], 14, TUILE, a)
  end
end

local function voiles_mesures(case, a)
  for i = 0, 7 do
    local x, y, w, h = case(i)
    voiles({{x + 4, y + h * 0.20, w - 8, h * 0.78}}, a)
  end
end

local function prevision_tuile(p, x, y, w, h, t)
  tuile(x, y, w, h)
  texte(sans, JOURS_COURTS[p.jour] .. " " .. p.quantieme, x + w / 2, y + 50, 38, PALE, "c")
  animation(p.anim, x + w / 2 - 72, y + 160, 0.95, t)
  temperature(gras, p.max, x + w - 36, y + 150, 64, BLANC, "d")
  temperature(sans, p.min, x + w - 36, y + 208, 44, PALE, "d")
  if p.pluie then
    texte(sans, "Pluie " .. entier(p.pluie) .. " %", x + w / 2, y + 285, 30, BLEU, "c")
  end
end

local function prevision_ligne(p, x, y, w, h, t)
  tuile(x, y, w, h)
  texte(gras, JOURS_COURTS[p.jour] .. " " .. p.quantieme, x + 36, y + 72, 42, BLANC, "g")
  animation(p.anim, x + 320, y + h / 2, 0.48, t)
  temperature(gras, p.max, x + 560, y + 74, 50, BLANC, "c")
  temperature(sans, p.min, x + 690, y + 74, 44, PALE, "c")
  if p.pluie then
    texte(sans, "Pluie " .. entier(p.pluie) .. " %", x + w - 36, y + 72, 36, BLEU, "d")
  end
end

-- Temperature actuelle : grand thermometre, valeur, libelle et tendance
local function temps_actuel(xa, xt, xv, xl, xf, cy, ts, t)
  local e = meteo.ecarts or {}
  animation(meteo.anim or "nuageux", xa, cy, 0.90, t)
  place(xt, cy - 8, 0.82, thermometre, meteo.temperature, t)
  local v = meteo.temperature and entier(meteo.temperature) or "--"
  temperature(gras, meteo.temperature, xv, cy + 58, ajuste(gras, v, 135, 230), BLANC, "d")
  libelle(libelle_meteo(ts), xl, cy - 20, 34, 310)
  fleche(xf, cy + 64, e.temperature, 0.5, 1.7)
  ecart_degres(sans, e.temperature, xf + 26, cy + 75, 30, BLANC, "g")
end

local function paysage(d, age, t, ts, rang, voile)
  local nom = meteo.ville or "Sarrebourg"
  local function case(i) return 40 + i * 231.14, 251, 222, 235 end

  tuile(40, 30, 860, 205)
  texte(gras, nom, 80, 78, ajuste(gras, nom, 42, 420), OR, "g")
  points_villes(92, 100, rang)
  texte(gras, string.format("%02d:%02d", d.hour, d.min), 80, 212, 118, BLANC, "g")
  texte(gras, JOURS[d.wday - 1], 860, 88, 58, BLANC, "d")
  texte(gras, tostring(d.day), 860, 168, 92, BLANC, "d")
  local mois = MOIS[d.month] .. " " .. d.year
  texte(sans, mois, 860, 216, ajuste(sans, mois, 42, 370), PALE, "d")

  tuile(920, 30, 960, 205)
  temps_actuel(1050, 1215, 1520, 1550, 1566, 132, ts, t)

  mesures(case, age, d.hour * 60 + d.min, t)

  courbe(40, 502, 1840, 215, 170, true)

  local previsions = meteo.previsions or {}
  for i, p in ipairs(previsions) do
    prevision_tuile(p, 40 + (i - 1) * 371, 733, 356, 317, t)
  end

  voiles({{60, 38, 460, 52}, {930, 38, 940, 189}, {212, 512, 1660, 196}}, voile)
  voiles_mesures(case, voile)
  for i = 1, 5 do
    voiles({{40 + (i - 1) * 371 + 8, 805, 340, 237}}, voile)
  end
end

local function portrait(d, age, t, ts, rang, voile)
  local nom = meteo.ville or "Sarrebourg"
  local date = JOURS[d.wday - 1] .. " " .. d.day .. " " .. MOIS[d.month] .. " " .. d.year
  local function case(i)
    return 40 + (i % 4) * 253.3, 597 + math.floor(i / 4) * 220, 240, 208
  end

  tuile(40, 30, 1000, 320)
  texte(gras, nom, 540, 92, ajuste(gras, nom, 54, 920), OR, "c")
  points_villes(540, 118, rang, true)
  texte(gras, string.format("%02d:%02d", d.hour, d.min), 540, 245, 130, BLANC, "c")
  texte(sans, date, 540, 322, ajuste(sans, date, 54, 920), PALE, "c")

  tuile(40, 366, 1000, 215)
  temps_actuel(150, 300, 630, 660, 678, 475, ts, t)

  mesures(case, age, d.hour * 60 + d.min, t)

  courbe(40, 1037, 1000, 225, 14, false)

  for i, p in ipairs(meteo.previsions or {}) do
    prevision_ligne(p, 40, 1278 + (i - 1) * 124, 1000, 112, t)
  end

  voiles({{60, 40, 960, 64}, {50, 376, 980, 195}, {50, 1085, 980, 170}}, voile)
  voiles_mesures(case, voile)
  for i = 1, 5 do
    voiles({{240, 1278 + (i - 1) * 124 + 6, 790, 100}}, voile)
  end
end

function node.render()
  local t   = sys.now()
  local ts  = os.time()

  -- Ville affichee, a tour de role
  local rang = 1
  local voile = 0
  if #villes > 1 then
    rang = math.floor(t / duree_ville) % #villes + 1
    local p = t % duree_ville
    voile = math.max(0, 1 - p / 0.4, 1 - (duree_ville - p) / 0.4)
  end
  meteo = villes[rang] or {}

  local utc = os.date("!*t", ts)
  local d   = os.date("!*t", ts + (meteo.decalage or decalage_paris(utc)))
  teinte(d.hour * 60 + d.min)

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

  if L < H then
    portrait(d, age_lune(ts), t, ts, rang, voile)
  else
    paysage(d, age_lune(ts), t, ts, rang, voile)
  end
end
