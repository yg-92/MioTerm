import Foundation
import Testing
@testable import MioTermCore

@Suite("shell 路径引用")
struct ShellQuotingTests {
    @Test("单引号包裹，内部单引号先关引号再补一个转义引号")
    func singleQuoting() {
        #expect(ShellQuoting.singleQuoted("a b") == "'a b'")
        #expect(ShellQuoting.singleQuoted("it's") == "'it'\\''s'")
        #expect(ShellQuoting.singleQuoted("") == "''")
    }

    @Test("干净路径原样保留，元字符才加引号")
    func quotesOnlyWhenNeeded() {
        for plain in ["/var/log", "./a.txt", "dir/sub:80", "文件.txt"] {
            #expect(ShellQuoting.quoteIfNeeded(plain) == plain, "不该给 \(plain) 加引号")
        }
        for risky in ["a b", "a$b", "a`b", "a(b)", "a;b", "a|b", "a*b", "a?b", "a#b", "a&b", "a<b", "a\nb", ""] {
            #expect(ShellQuoting.quoteIfNeeded(risky) == ShellQuoting.singleQuoted(risky))
        }
    }

    @Test("引号里的内容按 POSIX 规则还原成原值")
    func expectedQuotedForms() {
        // 逐个写死期望值：单引号内只有 '\'' 这一种逃逸，别的都是字面量。
        #expect(ShellQuoting.quoteIfNeeded("空格 目录") == "'空格 目录'")
        #expect(ShellQuoting.quoteIfNeeded("it's here") == "'it'\\''s here'")
        #expect(ShellQuoting.quoteIfNeeded("$HOME/x") == "'$HOME/x'")
        #expect(ShellQuoting.quoteIfNeeded("a;b|c") == "'a;b|c'")
    }
}
