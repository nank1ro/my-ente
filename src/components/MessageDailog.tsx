import React from 'react';
import { Button, Modal } from 'react-bootstrap';

interface Props {
    show: boolean;
    children;
    onHide: () => void;
    attributes: {
        title: string;
        close: { text: string; action: any };
        proceed: { text: string; action: any };
    };
}
export function MessageDialog({ attributes, children, ...props }: Props) {
    return (
        <Modal {...props} size="lg" centered>
            <Modal.Body>
                {attributes.title && (
                    <Modal.Title>
                        <strong>{attributes.title}</strong>
                        <hr />
                    </Modal.Title>
                )}
                {children}
            </Modal.Body>
            <Modal.Footer style={{ borderTop: 'none' }}>
                {attributes.close && (
                    <Button variant="danger" onClick={attributes.close.action}>
                        {attributes.close.text}
                    </Button>
                )}
                {attributes.proceed && (
                    <Button
                        variant="success"
                        onClick={attributes.proceed.action}
                    >
                        {attributes.proceed.text}
                    </Button>
                )}
            </Modal.Footer>
        </Modal>
    );
}
