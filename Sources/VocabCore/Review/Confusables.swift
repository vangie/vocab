import Foundation

/// Commonly confused English words (self-written list, MIT). Each line is one group.
/// Members of a group are always preferred distractors for each other and bypass the synonym filter:
/// they are *meant* to look or sound alike while meaning different things.
public enum Confusables {
    static let raw = """
    affect effect
    advice advise
    accept except
    access excess
    adapt adopt adept
    addition edition
    adverse averse
    aisle isle
    allude elude
    allusion illusion delusion
    altar alter
    ascent assent
    assure ensure insure
    bare bear
    berth birth
    beside besides
    boarder border
    brake break
    breath breathe
    bridal bridle
    canvas canvass
    capital capitol
    censor censure sensor
    cite site sight
    climatic climactic
    coarse course
    collision collusion
    complement compliment
    conscience conscious
    conscientious conscious
    continual continuous
    council counsel
    credible credulous creditable
    currant current
    decent descent dissent
    defuse diffuse
    dependant dependent
    deprecate depreciate
    desert dessert
    device devise
    discreet discrete
    disinterested uninterested
    dual duel
    elicit illicit
    eligible illegible
    emigrate immigrate
    emigrant immigrant
    eminent imminent immanent
    empathy sympathy
    envelop envelope
    exalt exult
    explicit implicit
    faint feint
    farther further
    flaunt flout
    flair flare
    formally formerly
    forth fourth
    foreword forward
    gorilla guerrilla
    hoard horde
    historic historical
    human humane
    imply infer
    incite insight
    ingenious ingenuous
    inequity iniquity
    insidious invidious
    its it's
    later latter
    lay lie
    lead led
    lessen lesson
    liable libel
    lightening lightning
    loath loathe
    loose lose loss
    luxuriant luxurious
    material materiel
    meddle medal metal mettle
    moral morale
    naval navel
    ordinance ordnance
    pail pale
    palate palette pallet
    passed past
    peace piece
    peak peek pique
    pedal peddle
    perpetrate perpetuate
    persecute prosecute
    personal personnel
    perspective prospective
    plain plane
    pore pour poor
    practical practicable
    pray prey
    precede proceed
    prescribe proscribe
    presence presents
    principal principle
    prophecy prophesy
    quiet quite quit
    rain reign rein
    raise raze rise
    respectfully respectively
    reverend reverent
    role roll
    sensual sensuous
    shear sheer
    sole soul
    stationary stationery
    statue stature statute
    straight strait
    suite sweet
    tenant tenet
    than then
    their there
    threw through thorough
    tortuous torturous
    track tract
    troop troupe
    turbid turgid
    vain vane vein
    vary very
    venal venial
    veracious voracious
    waist waste
    waive wave
    weather whether
    wet whet
    which witch
    who's whose
    yoke yolk
    adjoin adjourn
    appraise apprise
    biannual biennial
    cache cash
    callous callus
    casual causal
    cavalry calvary
    clench clinch
    comprise compose
    contemptible contemptuous
    corps corpse
    definite definitive
    deference difference
    detract distract
    economic economical
    effective efficient
    elusive illusive
    enquire inquire
    especially specially
    expand expend
    extant extinct
    fiscal physical
    gourmand gourmet
    illegal illicit
    imitate intimate
    impassable impassive
    incredible incredulous
    induce deduce
    infect inflict
    intense intent
    judicial judicious
    lose loose
    marital martial
    militate mitigate
    noisome noisy
    oral aural verbal
    oppress repress suppress
    precedence precedents
    preposition proposition
    proceed precede
    prostate prostrate
    quell quench
    recent resent
    regretful regrettable
    sight site
    simple simplistic
    stimulant stimulus
    systematic systemic
    team teem
    temerity timidity
    uninterested disinterested
    vocation avocation
    wander wonder
    """

    public static let groups: [[String]] = raw.split(separator: "\n").map {
        $0.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }.filter { $0.count >= 2 }

    static let index: [String: [String]] = {
        var m: [String: [String]] = [:]
        for g in groups { for w in g { m[w, default: []].append(contentsOf: g.filter { $0 != w }) } }
        return m.mapValues { var seen = Set<String>(); return $0.filter { seen.insert($0).inserted } }
    }()

    /// Words commonly confused with `word` (case-insensitive), in list order.
    public static func partners(of word: String) -> [String] { index[word.lowercased()] ?? [] }
}
