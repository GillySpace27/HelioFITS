//
//  FITSToolbar.swift: the Limb, Diff, Stretch and Filter controls and the stretch panel.
//  Moved from HelioFITSExtension/FITSPreviewCore.swift by HF-7.
//

import AppKit
import HelioFITSCore

// MARK: - Shared toolbar

/// The ◯ Δ ◐ tool cluster + stretch panel, wired to a model. Both surfaces build
/// theirs from here so the controls, tooltips and behaviour can't diverge.
final class FITSToolbar {
    let limb = NSButton(), diff = NSButton(), tune = NSButton()
    let filterMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    let panel = NSView()
    let sLo = NSSlider(), sHi = NSSlider(), sG = NSSlider()
    let cLog = NSButton(checkboxWithTitle: "log", target: nil, action: nil)
    let reset = NSButton(title: "Reset", target: nil, action: nil)
    /// Shows the percentile sliders' effect in real data units (#12).
    let limitsLabel = NSTextField(labelWithString: "")

    /// - Parameter target: receives the actions; must implement the selectors.
    init(target: AnyObject, limbSel: Selector, diffSel: Selector,
         tuneSel: Selector, stretchSel: Selector, resetSel: Selector, filterSel: Selector) {
        // These float over the image. A standard translucent bezel disappears
        // against a bright solar disk, so draw them as solid, near-opaque chips.
        func mk(_ b: NSButton, _ title: String, _ tip: String, _ sel: Selector) {
            b.title = title
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            b.layer?.borderWidth = 1
            b.toolTip = tip
            b.target = target
            b.action = sel
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 58).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        // Text labels, not glyphs: Quick Look does not fire tooltips, so a ◯/Δ/◐
        // was undecodable there (and read as "black circle" to VoiceOver). The
        // word is the label; the tooltip carries the fuller explanation.
        mk(limb, "Limb", "Show the solar limb: the photosphere's edge, from RSUN_OBS", limbSel)
        mk(diff, "Diff", "Running difference: this HDU minus the previous one (how CMEs, waves and dimmings are spotted)", diffSel)
        mk(tune, "Stretch", "Adjust the brightness stretch (percentile clip, gamma, log)", tuneSel)
        limb.setAccessibilityLabel("Show solar limb")
        diff.setAccessibilityLabel("Running difference with previous layer")
        tune.setAccessibilityLabel("Adjust brightness stretch")

        // Enhancement filter picker. RHEF (Radial Histogram Equalizing Filter,
        // Gilly & Cranmer 2025) removes the corona's radial brightness gradient
        // to reveal faint off-limb structure at every height. MGN/WOW are coming.
        filterMenu.appearance = NSAppearance(named: .darkAqua)
        filterMenu.translatesAutoresizingMaskIntoConstraints = false
        filterMenu.bezelStyle = .rounded
        filterMenu.controlSize = .regular
        filterMenu.toolTip = "Enhancement filter"
        filterMenu.setAccessibilityLabel("Enhancement filter")
        // Only ship implemented filters; greyed "(soon)" items read as unfinished
        // (panel feedback). Descriptive titles so the bare acronym isn't the whole
        // story where tooltips don't fire. Menu index still maps to Filter.rawValue.
        for f in FITSPreviewModel.Filter.allCases where f == .none || f == .rhef {
            filterMenu.addItem(withTitle: f == .rhef ? "RHEF: reveal faint corona" : "No filter")
        }
        filterMenu.target = target
        filterMenu.action = filterSel
        filterMenu.heightAnchor.constraint(equalToConstant: 26).isActive = true

        panel.wantsLayer = true
        // Dark appearance so the sliders/checkbox render with dark-mode contrast
        // on our dark panel rather than washed-out light-mode controls.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.97).cgColor
        panel.layer?.cornerRadius = 8
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(calibratedWhite: 0.25, alpha: 1).cgColor
        panel.isHidden = true

        func row(_ name: String, _ s: NSSlider, _ lo: Double, _ hi: Double,
                 _ v: Double, _ tip: String) -> NSStackView {
            s.minValue = lo; s.maxValue = hi; s.doubleValue = v
            s.target = target; s.action = stretchSel
            s.isContinuous = true
            s.toolTip = tip
            let l = NSTextField(labelWithString: name)
            l.font = .systemFont(ofSize: 11)
            l.textColor = NSColor(calibratedWhite: 0.8, alpha: 1)
            l.setContentHuggingPriority(.required, for: .horizontal)
            let st = NSStackView(views: [l, s])
            st.spacing = 6
            return st
        }
        cLog.target = target; cLog.action = stretchSel
        cLog.toolTip = "Logarithmic scaling: brings out faint off-limb structure"
        reset.target = target; reset.action = resetSel
        reset.bezelStyle = .rounded
        reset.toolTip = "Back to the default stretch"

        limitsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        limitsLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        limitsLabel.lineBreakMode = .byTruncatingTail
        limitsLabel.toolTip = "The data values the display is currently clipped to"

        let bottom = NSStackView(views: [cLog, reset])
        bottom.spacing = 10
        let stack = NSStackView(views: [
            row("Low", sLo, 0, 1, Self.posLow(FITSRenderer.pLow),
                "Clip the darkest pixels to black. Logarithmic, reaching the median: fine control near 0%"),
            row("High", sHi, 0, 1, Self.posHigh(FITSRenderer.pHigh),
                "Clip the brightest pixels to white. Logarithmic: fine control near 100%, where a solar image's tail lives"),
            row("Gamma", sG, 0.1, 2, 0.5, "Below 1 brightens faint structure; above 1 darkens it"),
            limitsLabel,
            bottom,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
        ])
    }

    var stack: NSStackView {
        let s = NSStackView(views: [filterMenu, limb, diff, tune])
        s.spacing = 6
        return s
    }

    // The clip sliders are LOGARITHMIC in distance from their end of the
    // distribution, not linear in percentile. Solar images have a heavy tail:
    // on a typical AIA frame 90–99.5% moves the white point 461→2096 while
    // 99.5–100% moves it 2096→14966, so a linear percentile slider spends 95%
    // of its travel doing almost nothing and the last 5% doing everything.
    // Mapping travel to log(distance-from-the-end) gives even control instead.
    //
    // Positions are 0…1; percentiles are rounded so the defaults round-trip
    // EXACTLY, which `stretchIsDefault` depends on to keep the baked image.
    /// Low clip spans 0.01 … 50 %. Capping it at 10 % (the obvious symmetric
    /// choice against the high slider) left it with nothing to do: on an AIA
    /// frame the 0–10th percentile covers 8.75 counts out of a 15 000 range,
    /// so the slider moved the black point invisibly. Reaching the median gives
    /// it 108 counts, which is enough to clip the quiet Sun away and see
    /// off-limb structure. The tail is genuinely one-sided; matching the two
    /// ends numerically would just preserve the uselessness symmetrically.
    private static func pctLow(_ t: Double) -> Double { StretchScale.lowPercent(t) }
    private static func posLow(_ pct: Double) -> Double { StretchScale.lowPosition(pct) }
    private static func pctHigh(_ t: Double) -> Double { StretchScale.highPercent(t) }
    private static func posHigh(_ pct: Double) -> Double { StretchScale.highPosition(pct) }

    func readStretch() -> (lo: Double, hi: Double, gamma: Double, log: Bool) {
        (Self.pctLow(sLo.doubleValue), Self.pctHigh(sHi.doubleValue),
         sG.doubleValue, cLog.state == .on)
    }

    func readFilter() -> FITSPreviewModel.Filter {
        FITSPreviewModel.Filter(rawValue: filterMenu.indexOfSelectedItem) ?? .none
    }

    /// - Parameter cmapKey: the page's colormap, because the default gamma is
    ///   instrument-dependent: a signed magnetogram wants 1.0 (linear), and
    ///   anything else wants the faint-structure 0.5.
    func resetStretch(cmapKey: String? = nil) {
        sLo.doubleValue = Self.posLow(FITSRenderer.pLow)
        sHi.doubleValue = Self.posHigh(FITSRenderer.pHigh)
        sG.doubleValue = Double(FITSRenderer.defaultGamma(cmapKey))
        cLog.state = .off
    }

    /// Put the sliders where the given stretch says, so the panel opens showing
    /// the mapping the image was actually baked with.
    func adoptStretch(_ s: (lo: Double, hi: Double, gamma: Double, log: Bool)) {
        sLo.doubleValue = Self.posLow(s.lo)
        sHi.doubleValue = Self.posHigh(s.hi)
        sG.doubleValue = s.gamma
        cLog.state = s.log ? .on : .off
    }

    /// The Reset button for both Mac hosts: reset the model, move the sliders to
    /// the model's new stretch, then repaint the chips. Returns whether the host
    /// must re-render. Leaving out `adoptStretch` here desyncs sliders and image
    /// (the #14 class); ToolbarResetTests pins it.
    @discardableResult
    func applyReset(to model: FITSPreviewModel) -> Bool {
        let rerender = model.resetStretch(cmapKey: model.page?.res.cmapKey)
        adoptStretch(model.stretch)
        sync(model: model)
        return rerender
    }

    /// Paint one chip: opaque dark when off, solid amber when on, dimmed when
    /// unavailable. Drawn explicitly because a borderless button has no bezel to
    /// tint, and these sit over a bright image.
    private func paint(_ b: NSButton, on: Bool, enabled: Bool) {
        b.isEnabled = enabled
        b.setAccessibilityValue(on ? "on" : "off")   // state is otherwise only a fill colour
        let bg: NSColor = on ? NSColor(calibratedRed: 0.86, green: 0.63, blue: 0.20, alpha: 0.97)
                             : NSColor(calibratedWhite: 0.11, alpha: 0.92)
        let fg: NSColor = on ? .black : (enabled ? .white : NSColor(calibratedWhite: 1, alpha: 0.35))
        b.layer?.backgroundColor = bg.withAlphaComponent(enabled ? bg.alphaComponent : 0.55).cgColor
        b.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: on ? 0.5 : 0.28).cgColor
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .foregroundColor: fg,
            .font: NSFont.systemFont(ofSize: 13),
            .paragraphStyle: {
                let p = NSMutableParagraphStyle(); p.alignment = .center; return p
            }(),
        ])
    }

    /// Reflect model state in the controls.
    func sync(model: FITSPreviewModel) {
        paint(limb, on: model.limbOn, enabled: model.hasLimb)
        paint(diff, on: model.mode == .diff, enabled: model.canDiff)
        // The stretch composes with a filter rather than being clobbered by it
        // (#14): RHEF sets the ordering, the stretch maps that to the ramp.
        paint(tune, on: model.mode == .stretch, enabled: true)
        tune.toolTip = model.filter == .none
            ? "Adjust the brightness stretch (percentile clip, gamma, log)"
            : "Adjust the stretch applied on top of the \(model.filter.label) filter"
        panel.isHidden = (model.mode != .stretch)
        if let l = model.displayLimits() {
            let u = l.unit.isEmpty ? "" : " " + l.unit
            limitsLabel.stringValue = "min \(FITSRenderer.fmtValue(l.lo))\(u)\nmax \(FITSRenderer.fmtValue(l.hi))\(u)"
        } else if model.filter != .none {
            limitsLabel.stringValue = "clipping \(model.filter.label) output,\nnot raw data values"
        } else {
            limitsLabel.stringValue = ""
        }
        if filterMenu.indexOfSelectedItem != model.filter.rawValue {
            filterMenu.selectItem(at: model.filter.rawValue)
        }
    }
}
