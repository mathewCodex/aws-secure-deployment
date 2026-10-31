import os
import logging
from flask import Flask, jsonify
import pymysql

app = Flask(__name__)
app.logger.setLevel(logging.INFO)

def get_db_connection():
	return pymysql.connect(
	host=os.environ["DB_HOST"],
	port=int(os.environ.get("DB_PORT", "3306")),
	user=os.environ["DB_USER"],
	password=os.environ["DB_PASSWORD"],
	database=os.environ["DB_NAME"],
	connect_timeout=3,
	charset="utf8mb4",
	cursorclass=pymysql.cursors.DictCursor,
	autocommit=True,
	)

@app.get("/")
def index():
	return  jsonify(service="webstack", status="ok")
@app.get("/health")
def health():
	return jsonify(status="ok")

@app.get("/db")
def database_health():
	try:
		connection = get_db_connection()
		try:
			with connection.cursor() as cursor:
				cursor.execute("SELECT 1 AS healthy")
				row = cursor.fetchone()
		finally:
			connection.close()
		if not row or row["healthy"] != 1:
			return jsonify(status="error", database="unexpected result"), 503
		return jsonify(status="ok", database="connected")
	except Exceptiom:
		app.logger.exception("Database health check failed")
		return jsonify(status="error", database="unavailable"), 503












