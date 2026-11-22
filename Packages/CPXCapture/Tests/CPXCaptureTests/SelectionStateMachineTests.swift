import CoreGraphics
import Testing
@testable import CPXCapture

@Suite("SelectionStateMachine")
struct SelectionStateMachineTests {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

    private func selected(_ rect: CGRect) -> SelectionStateMachine {
        var machine = SelectionStateMachine(bounds: bounds)
        machine.select(rect)
        return machine
    }

    @Test func startsHoveringWithoutDetection() {
        let machine = SelectionStateMachine(bounds: bounds)
        #expect(machine.state == .hovering(detectedRect: nil))
        #expect(machine.selectionRect == nil)
        #expect(machine.highlightedRect == nil)
    }

    @Test func hoverUpdatesAreClampedToBounds() {
        var machine = SelectionStateMachine(bounds: bounds)
        machine.updateHover(detectedRect: CGRect(x: -50, y: 700, width: 200, height: 200))
        #expect(machine.state == .hovering(detectedRect: CGRect(x: 0, y: 700, width: 150, height: 100)))
        machine.updateHover(detectedRect: CGRect(x: 2000, y: 2000, width: 10, height: 10))
        #expect(machine.state == .hovering(detectedRect: nil))
    }

    @Test func clickSelectsDetectedRect() {
        var machine = SelectionStateMachine(bounds: bounds)
        let window = CGRect(x: 100, y: 100, width: 300, height: 200)
        machine.updateHover(detectedRect: window)
        machine.mouseDown(at: CGPoint(x: 150, y: 150))
        machine.mouseUp(at: CGPoint(x: 151, y: 151))
        #expect(machine.state == .selected(rect: window))
    }

    @Test func clickWithoutDetectionSelectsFullBounds() {
        var machine = SelectionStateMachine(bounds: bounds)
        machine.mouseDown(at: CGPoint(x: 10, y: 10))
        machine.mouseUp(at: CGPoint(x: 10, y: 10))
        #expect(machine.state == .selected(rect: bounds))
    }

    @Test func hoverUpdatesIgnoredOutsideHovering() {
        var machine = selected(CGRect(x: 10, y: 10, width: 50, height: 50))
        machine.updateHover(detectedRect: CGRect(x: 0, y: 0, width: 5, height: 5))
        #expect(machine.state == .selected(rect: CGRect(x: 10, y: 10, width: 50, height: 50)))
    }

    @Test func dragSelectsNormalizedCustomRect() {
        var machine = SelectionStateMachine(bounds: bounds)
        machine.updateHover(detectedRect: CGRect(x: 0, y: 0, width: 500, height: 500))
        machine.mouseDown(at: CGPoint(x: 400, y: 300))
        machine.mouseDragged(to: CGPoint(x: 200, y: 100))
        #expect(machine.state == .dragging(origin: CGPoint(x: 400, y: 300), current: CGPoint(x: 200, y: 100)))
        #expect(machine.selectionRect == CGRect(x: 200, y: 100, width: 200, height: 200))
        machine.mouseUp(at: CGPoint(x: 200, y: 100))
        #expect(machine.state == .selected(rect: CGRect(x: 200, y: 100, width: 200, height: 200)))
    }

    @Test func dragIsClampedToBounds() {
        var machine = SelectionStateMachine(bounds: bounds)
        machine.mouseDown(at: CGPoint(x: 900, y: 700))
        machine.mouseDragged(to: CGPoint(x: 1500, y: 1200))
        machine.mouseUp(at: CGPoint(x: 1500, y: 1200))
        #expect(machine.state == .selected(rect: CGRect(x: 900, y: 700, width: 100, height: 100)))
    }

    @Test func moveInsideSelection() {
        var machine = selected(CGRect(x: 100, y: 100, width: 200, height: 100))
        machine.mouseDown(at: CGPoint(x: 150, y: 150))
        #expect(machine.state == .moving(rect: CGRect(x: 100, y: 100, width: 200, height: 100), startPoint: CGPoint(x: 150, y: 150)))
        machine.mouseDragged(to: CGPoint(x: 200, y: 120))
        #expect(machine.selectionRect == CGRect(x: 150, y: 70, width: 200, height: 100))
        machine.mouseUp(at: CGPoint(x: 200, y: 120))
        #expect(machine.state == .selected(rect: CGRect(x: 150, y: 70, width: 200, height: 100)))
    }

    @Test func moveIsClampedAndKeepsGrabOffset() {
        var machine = selected(CGRect(x: 100, y: 100, width: 200, height: 100))
        machine.mouseDown(at: CGPoint(x: 150, y: 150))
        machine.mouseDragged(to: CGPoint(x: 0, y: 150)) // would move to x = -50
        #expect(machine.selectionRect == CGRect(x: 0, y: 100, width: 200, height: 100))
        // Cursor returns partway: the rect must not move until the cursor passes the grab anchor.
        machine.mouseDragged(to: CGPoint(x: 40, y: 150))
        #expect(machine.selectionRect == CGRect(x: 0, y: 100, width: 200, height: 100))
        machine.mouseDragged(to: CGPoint(x: 60, y: 150))
        #expect(machine.selectionRect == CGRect(x: 10, y: 100, width: 200, height: 100))
        machine.mouseDragged(to: CGPoint(x: 2000, y: 2000))
        #expect(machine.selectionRect == CGRect(x: 800, y: 700, width: 200, height: 100))
    }

    @Test(arguments: [
        (ResizeHandle.topLeft, CGPoint(x: 90, y: 310), CGRect(x: 90, y: 100, width: 210, height: 210)),
        (.top, CGPoint(x: 999, y: 320), CGRect(x: 100, y: 100, width: 200, height: 220)),
        (.topRight, CGPoint(x: 350, y: 350), CGRect(x: 100, y: 100, width: 250, height: 250)),
        (.right, CGPoint(x: 320, y: 0), CGRect(x: 100, y: 100, width: 220, height: 200)),
        (.bottomRight, CGPoint(x: 310, y: 50), CGRect(x: 100, y: 50, width: 210, height: 250)),
        (.bottom, CGPoint(x: 0, y: 80), CGRect(x: 100, y: 80, width: 200, height: 220)),
        (.bottomLeft, CGPoint(x: 50, y: 50), CGRect(x: 50, y: 50, width: 250, height: 250)),
        (.left, CGPoint(x: 60, y: 999), CGRect(x: 60, y: 100, width: 240, height: 200)),
    ])
    func resizeEachHandle(handle: ResizeHandle, target: CGPoint, expected: CGRect) throws {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        var machine = selected(rect)
        let start = try #require(SelectionStateMachine.handlePoints(for: rect)[handle])
        machine.mouseDown(at: start)
        #expect(machine.state == .resizing(rect: rect, handle: handle, startPoint: start))
        machine.mouseDragged(to: SelectionStateMachine.clampedPoint(target, in: bounds))
        #expect(machine.selectionRect == expected)
        machine.mouseUp(at: target)
        #expect(machine.state == .selected(rect: expected))
    }

    @Test func resizeFlipsHandleWhenCrossingAnchor() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 200)
        var machine = selected(rect)
        machine.mouseDown(at: CGPoint(x: 300, y: 300)) // top-right corner
        machine.mouseDragged(to: CGPoint(x: 50, y: 40))
        guard case let .resizing(newRect, handle, _) = machine.state else {
            Issue.record("Expected resizing state")
            return
        }
        #expect(newRect == CGRect(x: 50, y: 40, width: 50, height: 60))
        #expect(handle == .bottomLeft)
        machine.mouseDragged(to: CGPoint(x: 80, y: 90))
        #expect(machine.selectionRect == CGRect(x: 80, y: 90, width: 20, height: 10))
    }

    @Test func resizeIsClampedToBounds() {
        var machine = selected(CGRect(x: 100, y: 100, width: 200, height: 200))
        machine.mouseDown(at: CGPoint(x: 300, y: 300))
        machine.mouseDragged(to: CGPoint(x: 5000, y: 5000))
        machine.mouseUp(at: CGPoint(x: 5000, y: 5000))
        #expect(machine.state == .selected(rect: CGRect(x: 100, y: 100, width: 900, height: 700)))
    }

    @Test func handleHitTestPrefersCornersAndRespectsRadius() {
        let rect = CGRect(x: 100, y: 100, width: 10, height: 10)
        #expect(SelectionStateMachine.hitTestHandle(at: CGPoint(x: 101, y: 102), rect: rect, radius: 6) == .bottomLeft)
        #expect(SelectionStateMachine.hitTestHandle(at: CGPoint(x: 150, y: 150), rect: rect, radius: 6) == nil)
        let big = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(SelectionStateMachine.hitTestHandle(at: CGPoint(x: 50, y: 98), rect: big, radius: 6) == .top)
        #expect(SelectionStateMachine.hitTestHandle(at: CGPoint(x: 3, y: 50), rect: big, radius: 6) == .left)
    }

    @Test func arrowNudgeMovesOnePointAndClamps() {
        var machine = selected(CGRect(x: 0, y: 10, width: 100, height: 100))
        let nudged = machine.nudge(dx: 1, dy: 0)
        #expect(nudged)
        #expect(machine.state == .selected(rect: CGRect(x: 1, y: 10, width: 100, height: 100)))
        machine.nudge(dx: 0, dy: -1)
        #expect(machine.selectionRect == CGRect(x: 1, y: 9, width: 100, height: 100))
        machine.nudge(dx: -5, dy: 0)
        #expect(machine.selectionRect == CGRect(x: 0, y: 9, width: 100, height: 100))
        machine.nudge(dx: 0, dy: 10_000)
        #expect(machine.selectionRect == CGRect(x: 0, y: 700, width: 100, height: 100))
    }

    @Test func nudgeIgnoredWhileHovering() {
        var machine = SelectionStateMachine(bounds: bounds)
        let nudged = machine.nudge(dx: 1, dy: 1)
        #expect(nudged == false)
        #expect(machine.isHovering)
    }

    @Test func outsideClickKeepsPreviousSelection() {
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        var machine = selected(rect)
        machine.mouseDown(at: CGPoint(x: 600, y: 600))
        machine.mouseUp(at: CGPoint(x: 600, y: 600))
        #expect(machine.state == .selected(rect: rect))
    }

    @Test func outsideDragStartsNewSelection() {
        var machine = selected(CGRect(x: 100, y: 100, width: 100, height: 100))
        machine.mouseDown(at: CGPoint(x: 600, y: 600))
        machine.mouseDragged(to: CGPoint(x: 700, y: 650))
        machine.mouseUp(at: CGPoint(x: 700, y: 650))
        #expect(machine.state == .selected(rect: CGRect(x: 600, y: 600, width: 100, height: 50)))
    }

    @Test func resetReturnsToHovering() {
        var machine = selected(CGRect(x: 1, y: 1, width: 10, height: 10))
        machine.reset()
        #expect(machine.state == .hovering(detectedRect: nil))
    }

    @Test func handleFlipping() {
        #expect(ResizeHandle.topLeft.flipped(horizontally: true, vertically: false) == .topRight)
        #expect(ResizeHandle.topLeft.flipped(horizontally: true, vertically: true) == .bottomRight)
        #expect(ResizeHandle.top.flipped(horizontally: true, vertically: true) == .bottom)
        #expect(ResizeHandle.left.flipped(horizontally: true, vertically: false) == .right)
        #expect(ResizeHandle.bottom.flipped(horizontally: false, vertically: false) == .bottom)
    }
}
