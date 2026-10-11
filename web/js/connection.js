// One WebSocket to the Dart host, reconnecting with backoff. Workspace proxies
// may drop idle sockets, so an application-level ping keeps it alive.

export class Connection {
  constructor() {
    this.socket = null;
    this.handlers = new Map();
    this.statusListeners = new Set();
    this.attempt = 0;
    this.heartbeat = null;
    this.reconnectTimer = null;
    this.stopped = false;
    this.state = 'connecting';
    window.addEventListener('beforeunload', () => {
      this.stopped = true;
      clearTimeout(this.reconnectTimer);
      clearInterval(this.heartbeat);
    });
  }

  get connected() {
    return this.socket !== null && this.socket.readyState === WebSocket.OPEN;
  }

  /** Subscribes to messages of one type ('*' receives every message). */
  on(type, handler) {
    if (!this.handlers.has(type)) this.handlers.set(type, new Set());
    this.handlers.get(type).add(handler);
    return () => this.handlers.get(type)?.delete(handler);
  }

  onStatus(listener) {
    this.statusListeners.add(listener);
    listener(this.state);
  }

  send(payload) {
    if (!this.connected) return false;
    this.socket.send(JSON.stringify(payload));
    return true;
  }

  connect() {
    if (this.stopped) return;
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    this.setState(this.attempt ? 'reconnecting' : 'connecting');
    const socket = new WebSocket(`${protocol}//${location.host}/ws`);
    this.socket = socket;
    socket.addEventListener('open', () => {
      if (this.socket !== socket) return;
      this.attempt = 0;
      this.setState('connected');
      clearInterval(this.heartbeat);
      this.heartbeat = setInterval(() => this.send({action: 'ping'}), 15000);
    });
    socket.addEventListener('message', event => {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch (error) {
        console.error('Invalid message from the Dart host', error);
        return;
      }
      if (!message || typeof message.type !== 'string') return;
      for (const key of [message.type, '*']) {
        for (const handler of this.handlers.get(key) ?? []) {
          try {
            handler(message);
          } catch (error) {
            console.error(`Handler for ${key} failed`, error);
          }
        }
      }
    });
    socket.addEventListener('close', () => {
      if (this.socket !== socket) return;
      clearInterval(this.heartbeat);
      this.heartbeat = null;
      this.socket = null;
      if (this.stopped) return;
      this.setState('disconnected');
      const delay = Math.min(5000, 400 * Math.pow(1.8, this.attempt++));
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = setTimeout(() => this.connect(), delay);
    });
  }

  setState(state) {
    this.state = state;
    for (const listener of this.statusListeners) listener(state);
  }
}
