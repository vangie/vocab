import Foundation

/// Vocab-side restyling of LDOCE5 (朗文当代高级英语辞典) entries to match Apple Dictionary / Oxford:
/// system font, one accent (headword), label colours for everything else, a quiet WORD FAMILY box
/// moved below the senses, monochrome speakers. Injected only into Longman entry documents (the
/// .dictionary bundle is untouched); every rule is scoped under Longman's own `.lm5ppbody` root.
public enum LongmanStyle {
    public static func applies(to dictionaryID: String) -> Bool {
        let id = dictionaryID.lowercased()
        return id.contains("ldoce") || id.contains("longman")
    }

    /// Collapses WORD FAMILY; a click on its heading toggles it. Without scripts it simply stays open.
    public static let script = """
    document.addEventListener('DOMContentLoaded', function () {
      // Per entry (homograph): its own usage boxes (COLLOCATIONS …), then its Related topics, at the
      // end of that entry. WORD FAMILY is shared by the whole page: once, at the very bottom.
      var entries = document.querySelectorAll('.lm5ppbody .ldoceEntry');
      for (var e = 0; e < entries.length; e++) {
        var en = entries[e];
        var bx = en.querySelectorAll(':scope > .lm5ppBox');
        for (var k = 0; k < bx.length; k++) en.appendChild(bx[k]);
        var t = en.querySelector(':scope > .topics_container');
        if (t) en.appendChild(t);
      }
      var fam = document.querySelector('.lm5ppbody .wordfams');
      if (fam && fam.parentNode) fam.parentNode.appendChild(fam);
      var boxes = document.querySelectorAll('.lm5ppbody .wordfams, .lm5ppbody .lm5ppBox');
      for (var i = 0; i < boxes.length; i++) {
        (function (box) {
          box.classList.add('v-collapsed');
          var h = box.querySelector('.lm5ppBoxHead') || box.querySelector('.LDOCE5pp_sensefold') || box;
          h.addEventListener('click', function (e) { e.preventDefault(); e.stopPropagation(); box.classList.toggle('v-collapsed'); });
        })(boxes[i]);
      }
    });
    """

    public static let css = """
    .lm5ppbody {
      --v-label: rgba(0,0,0,0.85); --v-secondary: rgba(0,0,0,0.55); --v-tertiary: rgba(0,0,0,0.38);
      --v-fill: rgba(0,0,0,0.04); --v-accent: -apple-system-control-accent;
    }
    @media (prefers-color-scheme: dark) {
      .lm5ppbody {
        --v-label: rgba(255,255,255,0.86); --v-secondary: rgba(255,255,255,0.55); --v-tertiary: rgba(255,255,255,0.36);
        --v-fill: rgba(255,255,255,0.05);
      }
    }
    .lm5ppbody, .lm5ppbody * {
      font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif !important;
      font-style: normal !important;
    }
    .lm5ppbody { color: var(--v-label) !important; font-size: 14px; line-height: 1.5; }
    .lm5ppbody a, .lm5ppbody .defRef, .lm5ppbody .crossRef, .lm5ppbody .REFHWD { color: inherit !important; text-decoration: none !important; }

    /* Headword: the only accent. */
    .lm5ppbody .Head { display: block; margin: 2px 0 6px; }
    .lm5ppbody .HWD { color: var(--v-accent) !important; font-size: 22px !important; font-weight: 600 !important; letter-spacing: 0; }
    .lm5ppbody .HYP, .lm5ppbody .HOMNUM { color: inherit !important; }
    .lm5ppbody .PronCodes, .lm5ppbody .PRON, .lm5ppbody .neutral { color: var(--v-secondary) !important; font-weight: 400 !important; }

    /* POS, grammar, register, region, field, signposts: secondary, small, non-italic. */
    .lm5ppbody .lm5pp_POS, .lm5ppbody .POS, .lm5ppbody .pos, .lm5ppbody .GRAM, .lm5ppbody .REGISTERLAB,
    .lm5ppbody .GEO, .lm5ppbody .geo, .lm5ppbody .FIELD, .lm5ppbody .ACTIV, .lm5ppbody .FREQ, .lm5ppbody .infllab,
    .lm5ppbody .SIGNPOST, .lm5ppbody .synopp, .lm5ppbody .topic {
      color: var(--v-secondary) !important; background: none !important; border: none !important;
      font-size: 12px !important; font-weight: 400 !important; text-transform: none !important; box-shadow: none !important;
    }
    .lm5ppbody .lm5pp_POS, .lm5ppbody .ACTIV, .lm5ppbody .SIGNPOST { font-variant: small-caps; letter-spacing: 0.02em; }
    .lm5ppbody .ACTIV, .lm5ppbody .SIGNPOST { margin-right: 4px; }

    /* Senses. */
    .lm5ppbody .Sense { margin: 8px 0 4px 1.6em !important; text-indent: 0 !important; }
    .lm5ppbody .refsensenum { color: inherit !important; font-weight: 400 !important; }
    .lm5ppbody .sensenum {
      color: var(--v-label) !important; font-weight: 700 !important; font-size: 14px !important;
      margin-left: -1.6em; display: inline-block; width: 1.6em;
    }
    .lm5ppbody .DEF { color: var(--v-label) !important; }
    .lm5ppbody .cn_txt { color: var(--v-tertiary) !important; }
    .lm5ppbody .LEXUNIT, .lm5ppbody .PROPFORM, .lm5ppbody .PROPFORMPREP, .lm5ppbody .COLLO, .lm5ppbody .EXP,
    .lm5ppbody .Exponent { color: var(--v-label) !important; font-weight: 600 !important; }

    /* Examples: secondary, indented; translations tertiary. */
    .lm5ppbody .EXAMPLE, .lm5ppbody .GramExa, .lm5ppbody .ColloExa {
      color: var(--v-secondary) !important; border: none !important; background: none !important;
      margin: 3px 0 3px 0.9em !important; padding: 0 !important;
    }
    .lm5ppbody .EXAMPLE .english, .lm5ppbody .EXAMPLE .en_txt, .lm5ppbody .COLLOINEXA, .lm5ppbody .GLOSS {
      color: var(--v-secondary) !important; font-weight: 400 !important;
    }
    .lm5ppbody .EXAMPLE .cn_txt { display: block; color: var(--v-tertiary) !important; }

    /* Speakers: monochrome secondary; BrE / AmE told apart by a tiny label. */
    .lm5ppbody .speaker, .lm5ppbody .speaker::before { color: var(--v-secondary) !important; }
    .lm5ppbody .speaker { font-size: 12px !important; margin: 0 2px; opacity: 0.85; }
    .lm5ppbody .speaker:hover { opacity: 1; }
    .lm5ppbody .speaker.brefile::after, .lm5ppbody .speaker.amefile::after {
      font-family: -apple-system, sans-serif !important; font-size: 9px; font-weight: 500; margin-left: 2px;
      color: var(--v-tertiary); vertical-align: 1px;
    }
    .lm5ppbody .speaker.brefile::after { content: "BrE"; }
    .lm5ppbody .speaker.amefile::after { content: "AmE"; }

    /* WORD FAMILY: quiet box below the senses. */
    .lm5ppbody .topics_container { margin: 10px 0 2px !important; padding: 5px 10px !important; }
    .lm5ppbody .topics_container .related_topics { font-size: 0 !important; }
    .lm5ppbody .topics_container .related_topics::before { content: "Related topics 相关话题: "; font-size: 11px; color: var(--v-secondary); }

    /* WORD FAMILY collapsed by default (LongmanStyle.script adds .v-collapsed; click the heading). */
    .lm5ppbody .wordfams .LDOCE5pp_sensefold { cursor: pointer; display: block; }
    .lm5ppbody .wordfams .asset_intro::after { content: " 词族 ▾"; font-size: 10px; text-transform: none; }
    .lm5ppbody .wordfams.v-collapsed .asset_intro::after { content: " 词族 ▸"; }
    .lm5ppbody .wordfams.v-collapsed .LDOCE_word_family { display: none !important; }
    .lm5ppbody .wordfams.v-collapsed { padding: 5px 10px !important; }
    .lm5ppbody .wordfams, .lm5ppbody .BoxPanel {
      background: var(--v-fill) !important; border: none !important; border-radius: 8px !important;
      box-shadow: none !important; padding: 8px 12px !important; margin: 12px 0 4px !important;
    }
    .lm5ppbody .wordfams .asset_intro, .lm5ppbody .lm5ppBoxHead, .lm5ppbody .BoxPanel .heading {
      color: var(--v-secondary) !important; background: none !important; font-size: 11px !important;
      font-weight: 600 !important; letter-spacing: 0.04em; text-transform: uppercase;
    }
    .lm5ppbody .LDOCE_word_family { display: block; margin-top: 2px; line-height: 1.7; }
    .lm5ppbody .wordfams .pos { display: inline-block !important; width: 5.5em; margin: 0 !important; padding: 0 !important; line-height: 22px; }
    .lm5ppbody .wordfams .w { display: inline !important; margin: 0 !important; padding: 0 !important; line-height: 22px; }
    .lm5ppbody .wordfams .pos::before, .lm5ppbody .wordfams .pos::after, .lm5ppbody .wordfams .w::before { content: none !important; }
    .lm5ppbody .wordfams .w::after { content: "\\A" !important; white-space: pre; display: inline !important; }

    /* Frequency dots, S1/W1, related topics: secondary, no colour. */
    .lm5ppbody .LDOCEVERSIONLOGO_new, .lm5ppbody .LDOCEVERSIONLOGO_new::before, .lm5ppbody .LEVEL { color: var(--v-tertiary) !important; font-size: 10px !important; letter-spacing: -1px; }
    .lm5ppbody .topics_container { background: var(--v-fill) !important; border: none !important; border-radius: 8px; }
    .lm5ppbody .topics_container, .lm5ppbody .topics_container *, .lm5ppbody .topics_container *::before,
    .lm5ppbody .topics_container::before { color: var(--v-secondary) !important; font-size: 12px !important; }
    .lm5ppbody .wordfams .w { color: var(--v-label) !important; font-weight: 400 !important; }
    .lm5ppbody .wordfams .w + .w { padding-left: 5.5em !important; }

    /* Collocation / usage boxes: quiet fill, no coloured border; section headings as small grey labels. */
    .lm5ppbody .lm5ppBox, .lm5ppbody .ColloBox { border: none !important; box-shadow: none !important; background: var(--v-fill) !important; border-radius: 8px !important; }
    .lm5ppbody .BoxPanel { background: none !important; }
    .lm5ppbody .SECHEADING { background: none !important; color: var(--v-secondary) !important; padding: 0 !important;
      font-size: 11px !important; font-weight: 600 !important; text-transform: uppercase; letter-spacing: 0.04em; border-radius: 0 !important; }
    .lm5ppbody .LDOCEVERSIONLOGO_new { display: none !important; }
    .lm5ppbody .lm5ppBox { padding: 6px 12px !important; margin: 10px 0 !important; }
    .lm5ppbody .lm5ppBoxHead { display: block; cursor: pointer; background: none !important; border: none !important;
      color: var(--v-secondary) !important; font-size: 11px !important; font-weight: 600 !important;
      letter-spacing: 0.04em; text-transform: uppercase; padding: 0 !important; margin: 0 !important; }
    .lm5ppbody .lm5ppBoxHead::before { content: none !important; }
    .lm5ppbody .lm5ppBoxHead::after { content: " ▾"; font-size: 10px; text-transform: none; }
    .lm5ppbody .ColloBox .lm5ppBoxHead::after { content: " 搭配 ▾"; }
    .lm5ppbody .ThesBox .lm5ppBoxHead::after { content: " 同义词 ▾"; }
    .lm5ppbody .GramBox .lm5ppBoxHead::after { content: " 语法 ▾"; }
    .lm5ppbody .UsageBox .lm5ppBoxHead::after, .lm5ppbody .F2NBox .lm5ppBoxHead::after { content: " 用法 ▾"; }
    .lm5ppbody .lm5ppBox.v-collapsed .lm5ppBoxHead::after { content: " ▸"; }
    .lm5ppbody .ColloBox.v-collapsed .lm5ppBoxHead::after { content: " 搭配 ▸"; }
    .lm5ppbody .ThesBox.v-collapsed .lm5ppBoxHead::after { content: " 同义词 ▸"; }
    .lm5ppbody .GramBox.v-collapsed .lm5ppBoxHead::after { content: " 语法 ▸"; }
    .lm5ppbody .UsageBox.v-collapsed .lm5ppBoxHead::after, .lm5ppbody .F2NBox.v-collapsed .lm5ppBoxHead::after { content: " 用法 ▸"; }
    .lm5ppbody .lm5ppBox.v-collapsed > :not(.lm5ppBoxHead) { display: none !important; }
    .lm5ppbody .lm5ppBox .BoxPanel { display: block; margin-top: 4px; }
    .lm5ppbody .lm5ppBox .COLLOC, .lm5ppbody .lm5ppBox .collo { color: var(--v-label) !important; font-weight: 600 !important; }
    .lm5ppbody .lm5ppBox .EXAMPLE { color: var(--v-secondary) !important; }
    .lm5ppbody .SECHEADING { border: none !important; outline: none !important; box-shadow: none !important; display: block; margin: 8px 0 2px !important; font-variant: small-caps; text-transform: none !important; font-size: 12px !important; }
    .lm5ppbody .wordfams .rootword { font-weight: 600 !important; }
    """
}
