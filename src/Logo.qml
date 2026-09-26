import QtQuick

// The Hymos mark (a mouse whose wheel trails into two easing curves), drawn
// from inline SVG so it takes any color: the bar tints it with the theme
// foreground and dims it while smooth scrolling is off. `weight` is the
// stroke width in viewBox units — heavier for the tiny bar icon.
Image {
    id: root

    property color color: "white"
    property real size: 16
    property real weight: 40

    width: size
    height: size
    sourceSize.width: Math.ceil(size * 2)
    sourceSize.height: Math.ceil(size * 2)
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true

    source: "data:image/svg+xml;utf8," + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="190 150 740 740">' +
        '<g fill="none" stroke="' + color.toString() + '" stroke-linecap="round" stroke-linejoin="round">' +
        '<path stroke-width="' + weight + '" d="M414 198c-108 0-184 83-184 191v246c0 108 76 191 184 191s184-83 184-191V389c0-108-76-191-184-191Z"/>' +
        '<path stroke-width="' + weight * 0.9 + '" d="M598 430c91 0 111-92 202-92 43 0 70 23 96 54M598 521c99 0 123 78 212 78 38 0 66-14 91-37"/>' +
        '</g></svg>')
}
