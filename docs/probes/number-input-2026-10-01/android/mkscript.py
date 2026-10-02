import sys
cases=open('../win/cases.txt',encoding='utf-8').read().split("\n")
def script(fmt_sent=lambda s:s):
    out=[]
    for i,c in enumerate(cases):
        s="7" if i%2==0 else "8"
        out += ["click number_field@amount",'set_text number_field@amount ""',f'type "{s}"',"press return",f'expect_value number_field@amount "{s}"',
                "click number_field@amount",'set_text number_field@amount ""']
        if all(' '<=ch<='~' for ch in c): out.append(f'type "{c}"')
        else: out.append(f'set_text number_field@amount "{c}"')
        out += ["press return", f'expect_value number_field@amount "CASE{i}"']
    return ";".join(out)+";"
if __name__=="__main__":
    print(script())
