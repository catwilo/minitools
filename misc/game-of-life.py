import numpy as np
import time
import os
import sys

def create_board(rows, cols, prob=0.5):
    """Crear un tablero aleatorio con una probabilidad dada para células vivas"""
    return np.random.choice([0, 1], size=(rows, cols), p=[1-prob, prob])

def count_neighbors(board):
    """Contar los vecinos vivos de cada célula"""
    neighbors = np.zeros_like(board)
    for i in range(-1, 2):
        for j in range(-1, 2):
            if i == 0 and j == 0:
                continue
            neighbors += np.roll(np.roll(board, i, axis=0), j, axis=1)
    return neighbors

def evolve(board):
    """Actualizar el tablero usando las reglas del juego de la vida"""
    neighbors = count_neighbors(board)
    new_board = (neighbors == 3) | ((board == 1) & (neighbors == 2))
    return new_board.astype(int)

def print_board_diff(board, prev_board):
    """Imprimir solo las celdas que han cambiado"""
    changes = []
    for i in range(board.shape[0]):
        for j in range(board.shape[1]):
            if board[i, j] != prev_board[i, j]:
                changes.append((i, j, board[i, j]))
    
    # Si no hay cambios, no hacemos nada
    if not changes:
        return
    
    print("\033[H", end="")  # Mover el cursor al inicio
    for i, j, state in changes:
        # Mover a la fila y columna correctas, y cambiar la celda
        print(f"\033[{i+1};{j+1}H{'█' if state else ' '}", end="")
    sys.stdout.flush()

def get_console_size():
    """Obtener el tamaño actual de la consola (filas y columnas)"""
    rows, cols = os.popen('stty size', 'r').read().split()
    return int(rows), int(cols)

def run_game(prob=0.2, delay=0.1):
    """Función principal para ejecutar el juego de la vida"""
    # Obtener tamaño de la consola
    rows, cols = get_console_size()

    # Crear tablero inicial con la probabilidad de células vivas
    board = create_board(rows, cols, prob)

    # Ejecutar el juego hasta que no queden células vivas
    generation = 0
    prev_board = np.copy(board)

    try:
        while np.sum(board) > 0:
            print_board_diff(board, prev_board)
            prev_board = np.copy(board)
            board = evolve(board)
            generation += 1
            time.sleep(delay)

    except KeyboardInterrupt:
        print(f"\nJuego terminado manualmente después de {generation} generaciones.")
        print(f"Células vivas finales: {np.sum(board)}")

if __name__ == "__main__":
    # Leer parámetros de línea de comandos
    if len(sys.argv) < 3:
        print("Uso: python game-of-life.py <probabilidad> <tiempo_de_actualización>")
        sys.exit(1)

    prob = float(sys.argv[1])
    delay = float(sys.argv[2])

    # Ejecutar el juego con los parámetros proporcionados
    run_game(prob, delay)

