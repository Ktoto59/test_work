import requests
import json


# Пример POST запроса
json_data = {
    'module': 'myname',
    'function': 'mytest',
    'data':
        {
            'ERROR number 1': {
              'ident': '2.1.11', 'value': ' test test '
            },
            'ERROR number 2': {
              'ident': '2.1.2', 'value': ' bla bla '
            },
            'ERROR number 3': {
              'ident': '2.5', 'value': 'Boo4 Boo Boo'
            },
            'ERROR number 4': {
            'ident': '2.1', 'value': 'Boo3 Boo Boo'
            },
            'ERROR number 5': {
                'ident': '2.1.1', 'value': 'Boo2 Boo Boo'
            },
            'ERROR number 7': {
              'ident': '2.1.131', 'value': 'Boo1 Boo Boo'
            },
            'ERROR number 8': {
              'ident': '1.3.101', 'value': 'Boo55 Boo Boo'
            },
            'ERROR number 9': {
              'ident': '2.1.401', 'value': 'Boo333 Boo Boo'
            },
            'ERROR number 6': {
              'ident': '2.2.101', 'value': 'Boo132 Boo Boo'
            }
        }
    }

# URL для отправки запроса
response = requests.post('http://127.0.0.1:5000/json/', json=json_data)

if response.status_code == 200:
    print("Data received and processed successfully.")
    print(response.text)
else:
    print(response.text)
