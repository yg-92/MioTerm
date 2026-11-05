import Foundation
import MioTermCore
import Testing

@Suite("终端左右分屏")
struct TerminalPaneLayoutTests {
    private let left = UUID()
    private let right = UUID()
    private let third = UUID()

    @Test func switchingTabsReplacesOnlyTheActivePane() {
        var layout = TerminalPaneLayout()
        layout.select(left)
        layout.split(with: right)
        layout.select(third)
        #expect(layout.primary == left)
        #expect(layout.secondary == third)
        #expect(layout.selected == third)
        layout.select(left)
        layout.select(right)
        #expect(layout.primary == right)
        #expect(layout.secondary == third)
    }

    @Test func selectingTheOtherVisiblePaneDoesNotSwapThem() {
        var layout = TerminalPaneLayout()
        layout.select(left)
        layout.split(with: right)
        layout.select(left)
        #expect(layout.primary == left)
        #expect(layout.secondary == right)
        #expect(layout.selected == left)
    }

    @Test func unsplittingKeepsTheActiveTerminal() {
        var layout = TerminalPaneLayout()
        layout.select(left)
        layout.split(with: right)
        layout.unsplit()
        #expect(layout.primary == right)
        #expect(layout.selected == right)
        #expect(!layout.isSplit)
    }

    @Test func closingEitherPaneKeepsTheOther() {
        for closingLeft in [true, false] {
            var layout = TerminalPaneLayout()
            layout.select(left)
            layout.split(with: right)
            layout.select(closingLeft ? left : right)
            layout.remove(closingLeft ? left : right)
            #expect(layout.primary == (closingLeft ? right : left))
            #expect(layout.selected == layout.primary)
            #expect(!layout.isSplit)
        }
    }

    @Test func closingABackgroundTabDoesNotChangeFocus() {
        var layout = TerminalPaneLayout()
        layout.select(left)
        layout.split(with: right)
        layout.remove(third)
        #expect(layout.primary == left)
        #expect(layout.secondary == right)
        #expect(layout.selected == right)
    }

    @Test func homePreservesTheSplitAndRestoresEitherPane() {
        var layout = TerminalPaneLayout()
        layout.select(left)
        layout.split(with: right)
        layout.showHome()
        #expect(layout.selected == nil)
        #expect(layout.isSplit)
        layout.select(left)
        #expect(layout.primary == left)
        #expect(layout.secondary == right)
        #expect(layout.selected == left)
    }

    @Test func closingOnHomeDoesNotSelectATerminal() {
        var layout = TerminalPaneLayout()
        layout.select(left)
        layout.split(with: right)
        layout.showHome()
        layout.remove(left)
        #expect(layout.selected == nil)
        #expect(layout.primary == right)
        #expect(!layout.isSplit)
    }

    @Test func cannotSplitWithoutASelectionOrDuplicateTheSameTerminal() {
        var layout = TerminalPaneLayout()
        layout.split(with: right)
        #expect(!layout.isSplit)
        layout.select(left)
        layout.split(with: left)
        #expect(!layout.isSplit)
        layout.remove(left)
        #expect(layout.primary == nil)
        #expect(layout.selected == nil)
    }

    @Test func explicitlyPairsAnyTwoOpenSessions() {
        var layout = TerminalPaneLayout()
        layout.select(third)
        layout.pair(left, with: right)
        #expect(layout.primary == left)
        #expect(layout.secondary == right)
        #expect(layout.selected == right)
    }

    @Test func choosingAnotherPartnerReplacesTheExistingCombination() {
        var layout = TerminalPaneLayout()
        layout.pair(left, with: right)
        layout.pair(right, with: third)
        #expect(layout.primary == right)
        #expect(layout.secondary == third)
        #expect(layout.selected == third)
    }

    @Test func delayedConnectionUsesTheOriginalBaseInsteadOfCurrentFocus() {
        var layout = TerminalPaneLayout()
        layout.select(left)
        let requestedBase = left
        layout.select(third)
        layout.pair(requestedBase, with: right)
        #expect(layout.primary == left)
        #expect(layout.secondary == right)
    }

    @Test func pairingTheSameSessionDoesNotDestroyTheCurrentCombination() {
        var layout = TerminalPaneLayout()
        layout.pair(left, with: right)
        layout.pair(third, with: third)
        #expect(layout.primary == left)
        #expect(layout.secondary == right)
        #expect(layout.selected == right)
    }
}
