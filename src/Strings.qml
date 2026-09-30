pragma Singleton
import QtQuick

// UI strings. `language` is "auto" (follow the system locale) or one of the
// keys below; anything missing falls back to English. Add a language by
// adding a table — every key in `en` is used somewhere.
QtObject {
    id: root

    property string language: "auto"

    readonly property string resolved: {
        var lang = language === "auto" ? Qt.locale().name.split("_")[0] : language;
        return tables[lang] ? lang : "en";
    }

    readonly property var tables: ({
        en: {
            on: "Smooth scrolling on", off: "Smooth scrolling off",
            tooltipOn: "Hymos · on", tooltipOff: "Hymos · off",
            intensity: "Intensity", intensityHint: "How far the page moves per wheel click",
            glide: "Glide", glideHint: "How long the scroll keeps gliding",
            level_low: "Low", level_medium: "Medium", level_high: "High", level_max: "Very high",
            glide_short: "Short", glide_medium: "Medium", glide_long: "Long", glide_max: "Very long",
            footer: "With Super/Ctrl/Alt held, and in games, the wheel stays in steps",
            error: "Couldn't start Hymos",
            tabWheel: "Wheel", tabDrag: "Drag",
            dragEnable: "Drag to scroll", dragEnableHint: "Scroll by holding a mouse button and moving it",
            clickSuppress: "Swallow the click", clickSuppressHint: "Hold the drag button down back so a drag never opens a context menu",
            dragButton: "Drag button",
            btnLeft: "Left", btnMiddle: "Middle", btnRight: "Right",
            dragDirection: "Direction", dirMobile: "Mobile", dirLaptop: "Grab and pull",
            dragSpeed: "Drag speed",
            dragFling: "Fling", dragFlingHint: "Keep gliding after the mouse stops moving",
            dragCoast: "Coast",
            dragButtonHint: "Which mouse button grabs the page while it is held",
            dragDirectionHint: "Mobile carries the page along with the cursor, like a finger; grab and pull lets the page trail behind",
            dragSpeedHint: "How far the page moves per pixel of mouse movement",
            dragCoastHint: "How long the glide lasts after you let go",
            dragFooter: "While dragging, the button never reaches the app, so no stray clicks or menus",
            curve: "Curve", curveHint: "How each scroll settles; all three cover the same distance", curveExpo: "Expo", curveLinear: "Linear", curveSmooth: "Smooth", axisLock: "One axis per drag", axisLockHint: "A drag follows the axis it started on, instead of drifting across both"
        },
        pt: {
            on: "Rolagem suave ligada", off: "Rolagem suave desligada",
            tooltipOn: "Hymos · ligado", tooltipOff: "Hymos · desligado",
            intensity: "Intensidade", intensityHint: "Quanto a página anda a cada clique da roda",
            glide: "Suavidade", glideHint: "Quanto tempo a rolagem continua deslizando",
            level_low: "Baixa", level_medium: "Média", level_high: "Alta", level_max: "Muito alta",
            glide_short: "Curta", glide_medium: "Média", glide_long: "Longa", glide_max: "Muito longa",
            footer: "Com Super/Ctrl/Alt apertado e em jogos a roda continua em passos",
            error: "Não foi possível iniciar o Hymos",
            tabWheel: "Roda", tabDrag: "Arrastar",
            dragEnable: "Arrastar para rolar", dragEnableHint: "Role segurando um botão do mouse e movendo",
            clickSuppress: "Engolir o clique", clickSuppressHint: "Segura o pressionar para que o arraste nunca abra um menu de contexto",
            dragButton: "Botão de arraste",
            btnLeft: "Esquerdo", btnMiddle: "Meio", btnRight: "Direito",
            dragDirection: "Direção", dirMobile: "Celular", dirLaptop: "Puxar e arrastar",
            dragSpeed: "Velocidade",
            dragFling: "Impulso", dragFlingHint: "Continua deslizando depois que o mouse para",
            dragCoast: "Deslize",
            dragButtonHint: "Qual botão do mouse segura a página",
            dragDirectionHint: "Celular leva a página junto com o cursor, como um dedo; puxar e arrastar deixa a página para trás",
            dragSpeedHint: "Quanto a página anda por pixel de movimento do mouse",
            dragCoastHint: "Quanto tempo o deslizamento dura depois de soltar",
            dragFooter: "Durante o arraste, o botão nunca chega ao aplicativo, sem cliques acidentais",
            curve: "Curva", curveHint: "Como cada rolagem assenta; as tres percorrem a mesma distancia", curveExpo: "Expo", curveLinear: "Linear", curveSmooth: "Suave", axisLock: "Um eixo por arraste", axisLockHint: "O arraste segue o eixo em que comecou, em vez de derivar pelos dois"
        },
        es: {
            on: "Desplazamiento suave activado", off: "Desplazamiento suave desactivado",
            tooltipOn: "Hymos · activado", tooltipOff: "Hymos · desactivado",
            intensity: "Intensidad", intensityHint: "Cuánto avanza la página por cada clic de la rueda",
            glide: "Suavidad", glideHint: "Cuánto tiempo sigue deslizándose el desplazamiento",
            level_low: "Baja", level_medium: "Media", level_high: "Alta", level_max: "Muy alta",
            glide_short: "Corta", glide_medium: "Media", glide_long: "Larga", glide_max: "Muy larga",
            footer: "Con Super/Ctrl/Alt pulsado y en juegos, la rueda sigue por pasos",
            error: "No se pudo iniciar Hymos",
            tabWheel: "Rueda", tabDrag: "Arrastrar",
            dragEnable: "Arrastrar para desplazar", dragEnableHint: "Desplaza manteniendo un botón del ratón y moviéndolo",
            clickSuppress: "Tragar el clic", clickSuppressHint: "Retiene la pulsación para que el arrastre nunca abra un menú contextual",
            dragButton: "Botón de arrastre",
            btnLeft: "Izquierdo", btnMiddle: "Medio", btnRight: "Derecho",
            dragDirection: "Dirección", dirMobile: "Móvil", dirLaptop: "Agarrar y tirar",
            dragSpeed: "Velocidad",
            dragFling: "Impulso", dragFlingHint: "Sigue deslizándose tras soltar el ratón",
            dragCoast: "Deslizamiento",
            dragButtonHint: "Qué botón del ratón mantiene agarrada la página",
            dragDirectionHint: "Móvil lleva la página con el cursor, como un dedo; agarrar y tirar deja la página detrás",
            dragSpeedHint: "Cuánto avanza la página por píxel de movimiento del ratón",
            dragCoastHint: "Cuánto dura el deslizamiento al soltar",
            dragFooter: "Mientras arrastras, el botón nunca llega a la aplicación, sin clics accidentales",
            curve: "Curva", curveHint: "Como se asienta cada desplazamiento; las tres recorren la misma distancia", curveExpo: "Expo", curveLinear: "Lineal", curveSmooth: "Suave", axisLock: "Un eje por arrastre", axisLockHint: "El arrastre sigue el eje en el que empezo, en vez de derivar por ambos"
        },
        fr: {
            on: "Défilement fluide activé", off: "Défilement fluide désactivé",
            tooltipOn: "Hymos · activé", tooltipOff: "Hymos · désactivé",
            intensity: "Intensité", intensityHint: "Distance parcourue par cran de molette",
            glide: "Glisse", glideHint: "Durée pendant laquelle le défilement continue de glisser",
            level_low: "Faible", level_medium: "Moyenne", level_high: "Forte", level_max: "Très forte",
            glide_short: "Courte", glide_medium: "Moyenne", glide_long: "Longue", glide_max: "Très longue",
            footer: "Avec Super/Ctrl/Alt enfoncé et dans les jeux, la molette reste cran par cran",
            error: "Impossible de démarrer Hymos",
            tabWheel: "Molette", tabDrag: "Glisser",
            dragEnable: "Glisser pour défiler", dragEnableHint: "Défilez en maintenant un bouton de la souris",
            clickSuppress: "Avaler le clic", clickSuppressHint: "Retient l'appui pour qu'un glissement n'ouvre jamais de menu contextuel",
            dragButton: "Bouton de glissement",
            btnLeft: "Gauche", btnMiddle: "Milieu", btnRight: "Droit",
            dragDirection: "Direction", dirMobile: "Mobile", dirLaptop: "Saisir et tirer",
            dragSpeed: "Vitesse",
            dragFling: "Élan", dragFlingHint: "Continue de glisser après l'arrêt de la souris",
            dragCoast: "Glissade",
            dragButtonHint: "Quel bouton de la souris saisit la page",
            dragDirectionHint: "Mobile entraîne la page avec le curseur, comme un doigt ; saisir et tirer laisse la page derrière",
            dragSpeedHint: "Distance parcourue par pixel de mouvement de la souris",
            dragCoastHint: "Durée du glissement après le relâchement",
            dragFooter: "Pendant le glissement, le bouton n'atteint jamais l'application, aucun clic parasite",
            curve: "Courbe", curveHint: "Comment chaque defilement se stabilise ; les trois couvrent la meme distance", curveExpo: "Expo", curveLinear: "Lineaire", curveSmooth: "Doux", axisLock: "Un axe par glissement", axisLockHint: "Le glissement suit l'axe ou il a commence, au lieu de deriver sur les deux"
        },
        de: {
            on: "Sanftes Scrollen an", off: "Sanftes Scrollen aus",
            tooltipOn: "Hymos · an", tooltipOff: "Hymos · aus",
            intensity: "Intensität", intensityHint: "Wie weit die Seite pro Mausrad-Raste scrollt",
            glide: "Gleiten", glideHint: "Wie lange das Scrollen nachgleitet",
            level_low: "Niedrig", level_medium: "Mittel", level_high: "Hoch", level_max: "Sehr hoch",
            glide_short: "Kurz", glide_medium: "Mittel", glide_long: "Lang", glide_max: "Sehr lang",
            footer: "Mit gedrückter Super/Strg/Alt-Taste und in Spielen scrollt das Rad weiter rastenweise",
            error: "Hymos konnte nicht gestartet werden",
            tabWheel: "Rad", tabDrag: "Ziehen",
            dragEnable: "Ziehen zum Scrollen", dragEnableHint: "Scrollen durch Halten einer Maustaste und Bewegen",
            clickSuppress: "Klick schlucken", clickSuppressHint: "Hält den Tastendruck zurück, damit Ziehen nie ein Kontextmenü öffnet",
            dragButton: "Zieh-Taste",
            btnLeft: "Links", btnMiddle: "Mitte", btnRight: "Rechts",
            dragDirection: "Richtung", dirMobile: "Mobil", dirLaptop: "Greifen und ziehen",
            dragSpeed: "Geschwindigkeit",
            dragFling: "Schwung", dragFlingHint: "Gleitet nach, sobald die Maus stoppt",
            dragCoast: "Nachlauf",
            dragButtonHint: "Welche Maustaste die Seite greift",
            dragDirectionHint: "Mobil bewegt die Seite mit dem Zeiger wie ein Finger; Greifen und ziehen lässt sie hinterher",
            dragSpeedHint: "Wie weit die Seite pro Pixel Mausbewegung scrollt",
            dragCoastHint: "Wie lange das Gleiten nach dem Loslassen dauert",
            dragFooter: "Beim Ziehen erreicht der Knopf die App nie, keine versehentlichen Klicks",
            curve: "Kurve", curveHint: "Wie jedes Scrollen ausklingt; alle drei decken dieselbe Strecke", curveExpo: "Expo", curveLinear: "Linear", curveSmooth: "Sanft", axisLock: "Eine Achse pro Ziehen", axisLockHint: "Das Ziehen folgt der Achse, auf der es begann, statt ueber beide zu driften"
        }
    })

    function t(key) {
        var table = tables[resolved] || tables.en;
        var s = table[key];
        return s !== undefined ? s : (tables.en[key] || key);
    }
}
