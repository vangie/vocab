import Foundation

/// A small, self-written table of common Latin/Greek roots and English affixes (MIT, part of Vocab).
public struct Morpheme: Hashable, Sendable {
    public enum Kind: String, Sendable { case prefix, root, suffix }
    public let kind: Kind
    public let forms: [String]
    public let meaning: String     // 中文
    public let gloss: String       // English
    public var display: String {
        switch kind {
        case .prefix: forms.map { $0 + "-" }.joined(separator: "/")
        case .suffix: forms.map { "-" + $0 }.joined(separator: "/")
        case .root: forms.joined(separator: "/")
        }
    }
}

public struct MorphemeMatch: Hashable, Sendable {
    public let morpheme: Morpheme
    public let form: String
    public let range: Range<Int>   // character offsets in the word
}

public enum RootTable {
    // kind|forms (comma)|中文|English
    static let raw = """
    p|a,an|无，非|not, without
    p|ab,abs|离开|away from
    p|ad,ac,af,ag,al,ap,ar,as,at|朝向，加强|to, toward
    p|ambi,amphi|两，周围|both, around
    p|ante|在前|before
    p|anti|反对|against
    p|auto|自己|self
    p|bene|好|good, well
    p|bi|二|two
    p|circum|环绕|around
    p|co,col,com,con,cor|共同|together, with
    p|contra,counter|相反|against
    p|de|向下，去除|down, away, undo
    p|di,dis,dif|分开，否定|apart, not
    p|dia|穿过|through, across
    p|dys|不良|bad, difficult
    p|e,ex,ef|向外|out of
    p|en,em|使…|make, put into
    p|epi|在上|upon
    p|eu|好|good
    p|extra,extro|超出|beyond
    p|fore|前|before
    p|hemi,semi|半|half
    p|hetero|异|different
    p|homo|同|same
    p|hyper|过度|over, excessive
    p|hypo|在下，不足|under
    p|il,im,in,ir|不，向内|not; into
    p|inter|在…之间|between
    p|intra,intro|在内|within
    p|mal,male|坏|bad
    p|micro|微小|small
    p|mis|错误|wrongly
    p|mono|单一|one
    p|multi|多|many
    p|neo|新|new
    p|non|非|not
    p|ob,oc,of,op|反对，朝向|against, toward
    p|omni|全|all
    p|pan|全|all
    p|para|旁，类似|beside
    p|per|贯穿，完全|through, thoroughly
    p|peri|周围|around
    p|poly|多|many
    p|post|在后|after
    p|pre|预先|before
    p|pro|向前，支持|forward, for
    p|re|再，回|again, back
    p|retro|向后|backward
    p|se|分离|apart
    p|sub,suc,suf,sup,sus|在下|under
    p|super,sur|在上，超|over, above
    p|syn,sym|共同|together
    p|tele|远|far
    p|trans|穿越|across
    p|tri|三|three
    p|ultra|极端|beyond
    p|un|不，相反|not, reverse
    p|uni|一|one
    p|under|在下，不足|below, too little
    p|over|过度|too much
    p|out|超过|beyond, more than
    r|act,ag|做，行动|do, act
    r|alter,alien|其他|other
    r|am,amor|爱|love
    r|anim|生命，心灵|life, mind
    r|ann,enn|年|year
    r|anthrop|人|human
    r|apt,ept|适合|fit
    r|aqu|水|water
    r|arch|统治，首要|rule, chief
    r|aud|听|hear
    r|bell|战争|war
    r|bio|生命|life
    r|brev|短|short
    r|cad,cas,cid|落下|fall
    r|cap,capt,cept,ceive,cip|拿，抓|take, seize
    r|capit|头|head
    r|carn|肉|flesh
    r|ced,ceed,cess|行走，让步|go, yield
    r|centr|中心|center
    r|cert|确定|sure
    r|chron|时间|time
    r|cide,cis|切，杀|cut, kill
    r|claim,clam|喊|shout
    r|clud,clus,clos|关闭|close
    r|cogn|知道|know
    r|cord|心|heart
    r|corp|身体|body
    r|cred|相信|believe
    r|cur,curs|跑|run
    r|cycl|圆，环|circle
    r|dem|人民|people
    r|dict|说|say
    r|doc,doct|教|teach
    r|dom|家，统治|home, rule
    r|duc,duct|引导|lead
    r|dur|持久|hard, lasting
    r|dyn|力量|power
    r|equ|相等|equal
    r|fac,fact,fect,fic|做|make, do
    r|fer|带，拿|carry
    r|fid|信任|faith
    r|fin|结束，界限|end, limit
    r|flect,flex|弯曲|bend
    r|flu,flux|流|flow
    r|form|形状|shape
    r|fort|强|strong
    r|fract,frag|破碎|break
    r|fus|倾注，熔|pour, melt
    r|gen|产生，种类|birth, kind
    r|geo|地|earth
    r|grad,gress|步，走|step, go
    r|graph,gram|写，画|write
    r|grat|感激，喜悦|pleasing, thanks
    r|grav|重|heavy
    r|hab,hibit|拥有，居住|have, hold
    r|hydr|水|water
    r|ject|投掷|throw
    r|jud,jur,jus|法律，判断|law, judge
    r|junct|连接|join
    r|lect,leg,lig|选择，读|choose, read
    r|liber|自由|free
    r|log,logy|言语，学科|word, study
    r|loqu,locu|说话|speak
    r|luc,lum|光|light
    r|man,manu|手|hand
    r|mand|命令|order
    r|mater,matr|母亲|mother
    r|medi|中间|middle
    r|mem|记忆|remember
    r|ment|心智|mind
    r|merg,mers|沉没|dip, sink
    r|meter,metr|测量|measure
    r|migr|迁移|move
    r|min|小|small
    r|mit,miss|送，放|send
    r|mob,mot,mov|移动|move
    r|mort|死|death
    r|mut|改变|change
    r|nat,nasc|出生|born
    r|nav|船|ship
    r|neg|否认|deny
    r|nom,nym|名字|name
    r|nov|新|new
    r|oper|工作|work
    r|pac|和平|peace
    r|pass,path|感情，忍受|feel, suffer
    r|pater,patr|父亲|father
    r|ped,pod|脚|foot
    r|pel,puls|推，驱动|push, drive
    r|pend,pens|悬挂，称量|hang, weigh
    r|phil|爱|love
    r|phon|声音|sound
    r|photo|光|light
    r|plic,plex,ply|折叠|fold
    r|pon,pos,pound|放置|put, place
    r|port|拿，运|carry
    r|prim|第一|first
    r|psych|心理|mind, soul
    r|quer,quest,quir|寻求|seek, ask
    r|rect|直，正|straight, right
    r|rupt|破裂|break
    r|scend|爬|climb
    r|sci|知道|know
    r|scrib,script|写|write
    r|sect,sec|切|cut
    r|sed,sess,sid|坐|sit
    r|sens,sent|感觉|feel
    r|sequ,secut|跟随|follow
    r|serv|服务，保持|serve, keep
    r|sign|标记|mark
    r|simil,simul|相似|like
    r|sol|单独，太阳|alone; sun
    r|solv,solu|松开|loosen
    r|son|声音|sound
    r|spec,spect,spic|看|look
    r|spir|呼吸|breathe
    r|sta,stat,stit|站立|stand
    r|strict,string|拉紧|tighten
    r|struct|建造|build
    r|sum,sumpt|拿，用|take
    r|tact,tang|触摸|touch
    r|temp,tempor|时间|time
    r|ten,tain,tent|握住|hold
    r|tend,tens|伸展|stretch
    r|terr|土地|earth
    r|test|证明|witness
    r|therm|热|heat
    r|tort|扭曲|twist
    r|tract|拉|pull
    r|vac|空|empty
    r|val,vail|价值，强|worth, strong
    r|ven,vent|来|come
    r|ver|真实|true
    r|vers,vert|转|turn
    r|vid,vis|看|see
    r|viv,vit|生命|life
    r|voc,vok|声音，叫|voice, call
    r|vol|意愿|wish
    r|volv,volu|卷，转|roll
    s|able,ible|能…的|able to be
    s|al,ial|…的|relating to
    s|ance,ence|状态，性质|state, quality
    s|ant,ent|…的人/物|one who
    s|ary,ory|…的，场所|relating to; place
    s|ate|使…|make
    s|cy|状态|state
    s|dom|领域，状态|state, realm
    s|ee|受动者|one who receives
    s|er,or|…的人|one who
    s|ess|女性|female
    s|ful|充满|full of
    s|fy,ify|使…化|make
    s|hood|身份，状态|state
    s|ic,ical|…的|relating to
    s|ion,tion,sion|行为，状态|act, state
    s|ism|主义|belief, practice
    s|ist|…者|one who
    s|ity,ty|性质|quality
    s|ive|有…性质的|tending to
    s|ize,ise|使…化|make
    s|less|没有|without
    s|ly|…地|in a manner
    s|ment|行为，结果|act, result
    s|ness|性质|state, quality
    s|ous,ious|具有…的|full of
    s|ship|身份，关系|state, skill
    s|some|易于…的|tending to
    s|ward|向|direction
    s|wise|方式|manner
    """

    public static let all: [Morpheme] = raw.split(separator: "\n").compactMap { line in
        let f = line.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4 else { return nil }
        let k: Morpheme.Kind = f[0] == "p" ? .prefix : f[0] == "s" ? .suffix : .root
        return Morpheme(kind: k, forms: f[1].split(separator: ",").map(String.init), meaning: f[2], gloss: f[3])
    }

    static let suffixForms: Set<String> = Set(all.filter { $0.kind == .suffix }.flatMap(\.forms))

    /// Morphemes found in the word, best first (roots, then prefixes, then suffixes; longer forms first).
    /// Rules keep false positives down: the rest of the word must stay ≥ 3 letters for affixes,
    /// one-letter affixes are ignored, roots need ≥ 3 letters, and proper nouns are skipped.
    public static func matches(_ word: String) -> [MorphemeMatch] {
        guard let f = word.first, f.isLowercase, word.allSatisfy({ $0.isLetter }) else { return [] }
        let w = Array(word)
        var out: [MorphemeMatch] = []
        for m in all {
            var best: MorphemeMatch?
            for form in m.forms {
                let n = form.count
                switch m.kind {
                case .prefix:
                    guard n >= 2, w.count - n >= 3, word.hasPrefix(form) else { continue }
                    if best == nil || n > best!.form.count { best = MorphemeMatch(morpheme: m, form: form, range: 0..<n) }
                case .suffix:
                    guard n >= 2, w.count - n >= 3, word.hasSuffix(form) else { continue }
                    if best == nil || n > best!.form.count { best = MorphemeMatch(morpheme: m, form: form, range: (w.count - n)..<w.count) }
                case .root:
                    guard n >= 3, w.count >= n + 2, let r = word.range(of: form) else { continue }
                    // "ment" in complement is the suffix -ment, not the root "mind".
                    if r.upperBound == word.endIndex, suffixForms.contains(form) { continue }
                    let lo = word.distance(from: word.startIndex, to: r.lowerBound)
                    if best == nil || n > best!.form.count { best = MorphemeMatch(morpheme: m, form: form, range: lo..<(lo + n)) }
                }
            }
            if let best { out.append(best) }
        }
        func rank(_ k: Morpheme.Kind) -> Int { k == .root ? 0 : k == .prefix ? 1 : 2 }
        return out.sorted { (rank($0.morpheme.kind), -$0.form.count) < (rank($1.morpheme.kind), -$1.form.count) }
    }
}
