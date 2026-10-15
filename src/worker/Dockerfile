FROM python:3.11

WORKDIR /app

COPY . /app

RUN pip install --no-cache-dir boto3==1.34.80

CMD ["python", "main.py"]
