// GF-792a — React entry point; mounts <App/> and loads the design tokens + app CSS.
import React from 'react';
import { createRoot } from 'react-dom/client';
import './styles/tokens.css';
import './styles/app.css';
import App from './App';

createRoot(document.getElementById('root')).render(<App />);
