import Foundation

@main struct DisfluencyChecks {
    static func main() {
        // Invented stationery/planning fixtures; never copy private recordings here.
        let cleanups: [(String, String)] = [
            ("哦哦，他他他标签贴在哪儿？行行行，你看你看抽屉，可能可能胶水用完了。", "哦，他标签贴在哪儿？行，你看抽屉，可能可能胶水用完了。"),
            ("她她她要订午餐，噢噢。", "她要订午餐，噢。"),
            ("我我我我这我这我想买两盒彩笔", "我想买两盒彩笔"),
            ("你你你是你你是整理书架的人", "你是整理书架的人"),
            ("这个这个书签", "这个书签"),
            ("就在就在二楼餐桌旁", "就在二楼餐桌旁"),
            ("午餐放到那个，放到那个储物盒里面", "午餐放到那个储物盒里面"),
            ("我们我们整理今天的清单", "我们整理今天的清单"),
            ("对对对对对", "对"),
            ("我们我们我们整理清单", "我们整理清单"),
            ("你你你们你们可以先吃", "你们可以先吃"),
            ("他他觉得这个这个API名称好记", "他觉得这个API名称好记"),
            ("我我不是说不吃", "我不是说不吃"),
            ("就在就在三号书柜", "就在三号书柜"),
            ("就在就在门口等午餐", "就在门口等午餐"),
            ("放到那个, 放到那个抽屉里", "放到那个抽屉里"),
            ("放到这个放到这个储物盒里面", "放到这个储物盒里面"),
            ("呃， 我我觉得这个这个书签是 22，API API。", "我觉得这个书签是 22，API API。"),
            ("um, 我们我们 use sum(n,n)，午餐放到那个，放到那个储物盒里面。", "我们 use sum(n,n)，午餐放到那个储物盒里面。"),
            ("这个这个 API 跟那个那个\tCSV 一样。", "这个 API 跟那个\tCSV 一样。"),
            ("就是就是今天，我们先我们先去数两盒铅笔", "就是今天，我们先去数两盒铅笔"),
            ("首先首先数这个，然后然后再看，应该应该不改22。", "首先数这个，然后再看，应该不改22。"),
            ("就是就是就是 API，不不不，先看看便签。", "就是 API，不不不，先看看便签。"),
            ("我们先我们先 use API API；看看看 sum(n,n)。", "我们先 use API API；看看 sum(n,n)。"),
            ("看看看这个书签，再再往上贴22。", "看看这个书签，再往上贴22。"),
            ("看看看看两盒铅笔，再再再往上看。", "看看两盒铅笔，再往上看。"),
            ("嗯，我我我先整理这个这个书签，API API，不不不，不能删掉否定。", "我先整理这个书签，API API，不不不，不能删掉否定。"),
            ("他说“我我我我这我这我想买两盒彩笔”，我我觉得可以。", "他说“我我我我这我这我想买两盒彩笔”，我觉得可以。"),
            ("示例：\"这个这个书签\"。我们我们整理清单。", "示例：\"这个这个书签\"。我们整理清单。"),
            ("don't change this；我我觉得可以。", "don't change this；我觉得可以。")
        ]
        let unchanged = [
            "我觉得可能可能性很大，不是完全确定。",
            "行行对应，行行行表格，哦哦公司。", "‘行行行’ ‘哦哦’ ‘他他他清单’",
            "对对", "对对对", "好好学习，人人参与，一一说明，看看结果。",
            "是不是这样，想一想，试一试，看一看。",
            "API API，CSV CSV，n n，22，2222，sum(n,n)，count(2,2)，n + n。",
            "我们整理清单。我们整理清单。", "这个书签，这个书签很重要。",
            "我，我先点餐。你，你把餐盒带来。", "好，好，好！很很很重要！",
            "不是不是，我还没吃午饭。", "不，不对，是两个；不是一个。",
            "放到这个，不，放到那个抽屉里。", "放到这个，但是放到这个盒子会太挤。",
            "你是你，我是我。", "这不是我们整理今天的清单。",
            "就在二楼餐桌旁", "就在三号书柜", "这边一共22个，那个有222个。",
            "放到这个。放到这个抽屉里。", "放到这个；放到这个抽屉里。",
            "“对对对对对” ‘我我觉得’ 「这个这个书签」 『我们我们整理清单』",
            "\"呃，  这个这个书签。。\"", "'um,  我我觉得'", "`API API sum(n,n) 22 这个这个书签`",
            "示例：“未结束的我我觉得这个这个书签", "示例：\"他说 \\\"这个这个书签\\\"。\"",
            "I I think that that works. We we should wait.",
            "这个这个", "我们我们", "我我我我", "我们我们\nuse API", "这个这个，API",
            "就是，就是这样。首先，首先数这个。然后，然后再看。应该，应该保留。",
            "我们先，我们先数两盒铅笔。", "看看这个书签，看看 API，看看22。",
            "看看看", "看看看看", "看看看，先停。", "看看看\n两盒铅笔。",
            "就是就是", "就是就是就是", "首先首先\n两盒铅笔。", "应该应该，不对。",
            "再再一遍，再，再往上。", "“就是就是今天，我们先我们先去数两盒铅笔，看看看，再再往上。”"
        ]
        for (input, expected) in cleanups {
            check(input, expected: expected)
        }
        for input in unchanged {
            check(input, expected: input)
        }

        // Opting out must retain the old filler-only presentation, including
        // its exact spacing and punctuation normalization.
        let originalBehavior: [(String, String)] = [
            ("我我我我这我这我想买两盒彩笔", "我我我我这我这我想买两盒彩笔"),
            ("你你你是你你是整理书架的人", "你你你是你你是整理书架的人"),
            ("午餐放到那个，放到那个储物盒里面", "午餐放到那个，放到那个储物盒里面"),
            ("  um,  hello. .,, ", "hello."),
            ("呃， 我们我们整理今天的清单", "我们我们整理今天的清单"),
            ("album human “um” 'uh'", "album human “um” 'uh'")
        ]
        for (input, expected) in originalBehavior {
            require(FillerReducer.reduce(input) == expected, "Default changed for \(input)")
            require(FillerReducer.reduce(input, reduceRepetitions: false) == expected, "Opt-out changed for \(input)")
        }
        print("PASS: \(cleanups.count) cleanup cases, \(unchanged.count) preservation cases, idempotence, and \(originalBehavior.count) first-pass compatibility cases")
    }

    private static func check(_ input: String, expected: String) {
        let actual = FillerReducer.reduce(input, reduceRepetitions: true)
        require(actual == expected, "Input: \(input)\nExpected: \(expected)\nActual: \(actual)")
        let again = FillerReducer.reduce(actual, reduceRepetitions: true)
        require(again == actual, "Not idempotent: \(input)\nFirst: \(actual)\nSecond: \(again)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
