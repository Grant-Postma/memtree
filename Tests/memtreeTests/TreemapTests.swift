import CoreGraphics
import Testing
@testable import memtree

// Swift Testing rather than XCTest: the Command Line Tools ship only this one.

@Test func areasAreProportionalAndFillTheRect() {
    let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
    let values = [6.0, 6, 4, 3, 2, 2, 1]
    let rects = Treemap.layout(values, in: rect)
    let total = values.reduce(0, +)
    var covered: CGFloat = 0
    for (value, tile) in zip(values, rects) {
        let expected = rect.width * rect.height * CGFloat(value / total)
        #expect(abs(tile.width * tile.height - expected) < 1)
        #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(tile))
        covered += tile.width * tile.height
    }
    #expect(abs(covered - rect.width * rect.height) < 1)
}

@Test func zerosGetEmptyRects() {
    let rects = Treemap.layout([3, 0, 1], in: CGRect(x: 0, y: 0, width: 100, height: 100))
    #expect(rects[1] == .zero)
    #expect(rects[0].width > 0)
}

@Test func tilesDoNotOverlap() {
    let rects = Treemap.layout([10, 8, 5, 5, 3, 1, 1, 0.5], in: CGRect(x: 0, y: 0, width: 300, height: 200))
    for i in rects.indices {
        for j in rects.indices where j > i {
            let overlap = rects[i].intersection(rects[j])
            #expect(overlap.isNull || overlap.width * overlap.height < 0.5)
        }
    }
}

@Test func helpersGroupUnderTheirOuterApp() {
    let group = Sampler.group(forPath:
        "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
    #expect(group.name == "Google Chrome")
    #expect(group.appPath == "/Applications/Google Chrome.app")
    #expect(Sampler.group(forPath: "/usr/libexec/trustd").key == "macos")
    #expect(Sampler.group(forPath: "/opt/homebrew/bin/node").name == "node")
    #expect(Sampler.group(forPath: "/usr/local/bin/droid").name == "droid")
}

@Test func cpuTimeParsing() {
    #expect(Sampler.parseCPUTime("0:01.50") == 1.5)
    #expect(abs(Sampler.parseCPUTime("82:44.36")! - 4964.36) < 0.001)
    #expect(Sampler.parseCPUTime("1:02:03.00") == 3723)
}

@MainActor @Test func orderIsStickyForNearEqualSizes() {
    // 2 is 5% larger than 1: not enough to pass it.
    #expect(LiveModel.stableOrder(previous: [1, 2], sizes: [1: 100, 2: 105]) == [1, 2])
    // 30% larger is: it moves ahead.
    #expect(LiveModel.stableOrder(previous: [1, 2], sizes: [1: 100, 2: 130]) == [2, 1])
    // Newcomers find their place; the departed are dropped.
    #expect(LiveModel.stableOrder(previous: [1, 2, 3], sizes: [1: 100, 3: 10, 4: 500]) == [4, 1, 3])
}
