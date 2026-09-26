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
            error: "Couldn't start Hymos"
        },
        pt: {
            on: "Rolagem suave ligada", off: "Rolagem suave desligada",
            tooltipOn: "Hymos · ligado", tooltipOff: "Hymos · desligado",
            intensity: "Intensidade", intensityHint: "Quanto a página anda a cada clique da roda",
            glide: "Suavidade", glideHint: "Quanto tempo a rolagem continua deslizando",
            level_low: "Baixa", level_medium: "Média", level_high: "Alta", level_max: "Muito alta",
            glide_short: "Curta", glide_medium: "Média", glide_long: "Longa", glide_max: "Muito longa",
            footer: "Com Super/Ctrl/Alt apertado e em jogos a roda continua em passos",
            error: "Não foi possível iniciar o Hymos"
        },
        es: {
            on: "Desplazamiento suave activado", off: "Desplazamiento suave desactivado",
            tooltipOn: "Hymos · activado", tooltipOff: "Hymos · desactivado",
            intensity: "Intensidad", intensityHint: "Cuánto avanza la página por cada clic de la rueda",
            glide: "Suavidad", glideHint: "Cuánto tiempo sigue deslizándose el desplazamiento",
            level_low: "Baja", level_medium: "Media", level_high: "Alta", level_max: "Muy alta",
            glide_short: "Corta", glide_medium: "Media", glide_long: "Larga", glide_max: "Muy larga",
            footer: "Con Super/Ctrl/Alt pulsado y en juegos, la rueda sigue por pasos",
            error: "No se pudo iniciar Hymos"
        },
        fr: {
            on: "Défilement fluide activé", off: "Défilement fluide désactivé",
            tooltipOn: "Hymos · activé", tooltipOff: "Hymos · désactivé",
            intensity: "Intensité", intensityHint: "Distance parcourue par cran de molette",
            glide: "Glisse", glideHint: "Durée pendant laquelle le défilement continue de glisser",
            level_low: "Faible", level_medium: "Moyenne", level_high: "Forte", level_max: "Très forte",
            glide_short: "Courte", glide_medium: "Moyenne", glide_long: "Longue", glide_max: "Très longue",
            footer: "Avec Super/Ctrl/Alt enfoncé et dans les jeux, la molette reste cran par cran",
            error: "Impossible de démarrer Hymos"
        },
        de: {
            on: "Sanftes Scrollen an", off: "Sanftes Scrollen aus",
            tooltipOn: "Hymos · an", tooltipOff: "Hymos · aus",
            intensity: "Intensität", intensityHint: "Wie weit die Seite pro Mausrad-Raste scrollt",
            glide: "Gleiten", glideHint: "Wie lange das Scrollen nachgleitet",
            level_low: "Niedrig", level_medium: "Mittel", level_high: "Hoch", level_max: "Sehr hoch",
            glide_short: "Kurz", glide_medium: "Mittel", glide_long: "Lang", glide_max: "Sehr lang",
            footer: "Mit gedrückter Super/Strg/Alt-Taste und in Spielen scrollt das Rad weiter rastenweise",
            error: "Hymos konnte nicht gestartet werden"
        }
    })

    function t(key) {
        var table = tables[resolved] || tables.en;
        var s = table[key];
        return s !== undefined ? s : (tables.en[key] || key);
    }
}
