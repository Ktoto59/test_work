# Основной модуль
def mytest(data):
    return sorted(data.items(), key=lambda item: item[1]['ident'])
