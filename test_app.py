# app.py - веб-сервис
from flask import Flask, request, jsonify, render_template
import importlib


app = Flask(__name__)
global_data = None


@app.route('/json/', methods=['POST'])
def sort_dictionary():
    """ Функция сортировки  """
    global global_data
    json_data = request.get_json()
    module_name = json_data['module']
    function_name = json_data['function']
    data = json_data['data']
    module = importlib.import_module(module_name)
    try:
        function = getattr(module, function_name)
    except AttributeError:
        return 'Unknown function {}'.format(function_name), 500

    sorted_data = function(data)

    # Сохранение данных в глобальной переменной
    global_data = sorted_data

    return jsonify(sorted_data)


@app.route('/html/')
def html_page():
    """ Страница с таблицей """
    return render_template('table.html', global_data=global_data)


def get_api_data():
    """ Функция формирования json'а для таблицы"""
    data = {'data': global_data}
    print(data)
    return jsonify(data)


@app.route('/api/data', methods=['GET'])
def api_data():
    return get_api_data()


if __name__ == '__main__':
    app.run(debug=True)
