import SwiftUI

/// Draws one frame of the map. Shared by the window and the recorder, so a
/// recording looks exactly like the app.
struct Painter {
    let texts: TextImages
    let metric: Metric
    let hovered: (group: DrawnGroup, child: DrawnTile?)?

    func paint(_ groups: [DrawnGroup], in context: inout GraphicsContext) {
        let format = { (value: Double) in LiveModel.format(value, metric: metric) }
        for group in groups {
            let rect = group.tile.rect
            guard rect.width >= 1, rect.height >= 1 else { continue }
            context.fill(Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 3), with: .color(group.tile.color))

            // Slivers under 2 pt read as the group's own colour anyway, and a
            // memory map has hundreds of them.
            for child in group.children where child.rect.width >= 2 && child.rect.height >= 2 {
                let tile = child.rect.insetBy(dx: 0.5, dy: 0.5)
                let path = min(tile.width, tile.height) < 8 ? Path(tile) : Path(roundedRect: tile, cornerRadius: 2)
                context.fill(path, with: .color(child.color))
                guard tile.width > 30, tile.height > 18 else { continue }
                let room = tile.width - 8
                var y = tile.minY + 3
                if let name = texts.label(child.label, style: .name, maxWidth: room) {
                    context.draw(name.image, in: CGRect(origin: CGPoint(x: tile.minX + 4, y: y), size: name.size))
                    y += name.size.height + 2
                }
                let valueText = texts.format(child.sampled, metric: metric, with: format)
                if tile.height > 38, let value = texts.label(valueText, style: .value, maxWidth: room),
                   value.size.width <= room {
                    context.draw(value.image, in: CGRect(origin: CGPoint(x: tile.minX + 4, y: y), size: value.size))
                }
            }

            guard group.header > 0 else { continue }
            var x = rect.minX + 6
            if let icon = group.icon, rect.width > 90 {
                context.draw(icon, in: CGRect(x: x, y: rect.minY + 3, width: 15, height: 15))
                x += 19
            }
            let room = rect.maxX - x - 6
            let valueText = texts.format(group.tile.sampled, metric: metric, with: format)
            let value = texts.label(valueText, style: .groupValue, maxWidth: .infinity)
            // The value keeps its place while the name is shortened.
            let valueRoom = value.map { $0.size.width + 8 } ?? 0
            let showValue = room - valueRoom > 40
            if let name = texts.label(group.tile.label, style: .groupName, maxWidth: showValue ? room - valueRoom : room) {
                let top = rect.minY + 2 + (group.header - 2 - name.size.height) / 2
                context.draw(name.image, in: CGRect(origin: CGPoint(x: x, y: top), size: name.size))
                if showValue, let value {
                    context.draw(value.image, in: CGRect(
                        origin: CGPoint(x: x + name.size.width + 8, y: top + (name.size.height - value.size.height) / 2),
                        size: value.size))
                }
            }
        }

        if let hovered {
            let amber = Color(red: 1, green: 0.72, blue: 0.2)
            context.stroke(Path(roundedRect: hovered.group.tile.rect.insetBy(dx: 1, dy: 1), cornerRadius: 3),
                           with: .color(amber.opacity(0.5)), lineWidth: 1)
            if let child = hovered.child {
                context.stroke(Path(roundedRect: child.rect.insetBy(dx: 1, dy: 1), cornerRadius: 2),
                               with: .color(amber), lineWidth: 2)
            }
        }
    }
}
